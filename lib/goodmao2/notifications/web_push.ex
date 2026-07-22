defmodule Goodmao2.Notifications.WebPush do
  @moduledoc """
  Web Push payload encryption (RFC 8291 + RFC 8188 `aes128gcm`) and delivery (ADR-0011 Stage 2).

  Every crypto primitive is Erlang `:crypto` — no external Web Push library. Encryption:

  1. ephemeral P-256 ECDH keypair → shared secret with the subscriber's `p256dh`
  2. HKDF-SHA256 from the subscriber `auth` secret → IKM, then CEK (16 B) + nonce (12 B)
  3. pad plaintext with the RFC 8188 `\\x02` delimiter, AES-128-GCM encrypt
  4. assemble the `aes128gcm` wire frame

  Delivery signs a VAPID JWT (`Vapid`), decrypts the private key (`VapidVault`), and POSTs
  through the SSRF-safe, DNS-pinned `SafeClient`. A `404`/`410` means the browser dropped the
  subscription, so it is soft-deleted.

  VAPID keys live in `Goodmao2.Settings` (managed from `/admin/settings`); when they are
  unset `vapid_configured?/0` is false and the whole feature stays dormant.
  """
  require Logger

  alias Goodmao2.Notifications.Notification
  alias Goodmao2.Notifications.PushSubscription
  alias Goodmao2.Notifications.WebPush.SafeClient
  alias Goodmao2.Notifications.WebPush.Vapid
  alias Goodmao2.Notifications.WebPush.VapidVault
  alias Goodmao2.Repo
  alias Goodmao2.Settings

  @public_key_setting "vapid_public_key"
  @private_key_setting "vapid_private_key_encrypted"
  @subject_setting "vapid_subject"
  @default_subject "mailto:admin@localhost"

  ## Configuration

  @doc "The base64url VAPID public key handed to the browser, or nil when unconfigured."
  def public_key, do: Settings.get(@public_key_setting)

  @doc "The VAPID contact (`mailto:`) claim; falls back to a placeholder."
  def subject, do: Settings.get(@subject_setting) || @default_subject

  @doc "True once a VAPID keypair has been generated and stored."
  def vapid_configured? do
    is_binary(public_key()) and is_binary(Settings.get(@private_key_setting))
  end

  @doc """
  Generates a fresh VAPID P-256 keypair.

  Returns `{public_key_base64url, encrypted_private_key_binary}` — the admin settings page
  persists these via `Settings.put/2` (the private key encrypted by `VapidVault`).
  """
  def generate_keypair do
    {public_key, private_key} = :crypto.generate_key(:ecdh, :prime256v1)
    {Base.url_encode64(public_key, padding: false), VapidVault.encrypt(private_key)}
  end

  ## Encryption (RFC 8291 + RFC 8188)

  @doc """
  Encrypts `plaintext` for a subscriber, producing the `aes128gcm` wire format:

      salt(16) || rs(4) || idlen(1) || server_public(65) || ciphertext || tag(16)
  """
  def encrypt(plaintext, subscriber_p256dh, subscriber_auth) do
    {server_public, server_private} = :crypto.generate_key(:ecdh, :prime256v1)
    shared_secret = :crypto.compute_key(:ecdh, subscriber_p256dh, server_private, :prime256v1)
    salt = :crypto.strong_rand_bytes(16)

    # PRK/IKM: HKDF-Extract(salt = subscriber auth, IKM = ECDH secret) then expand (RFC 8291 §3.4).
    auth_info = "WebPush: info\0" <> subscriber_p256dh <> server_public
    ikm = hkdf_sha256(subscriber_auth, shared_secret, auth_info, 32)

    cek = hkdf_sha256(salt, ikm, "Content-Encoding: aes128gcm\0", 16)
    nonce = hkdf_sha256(salt, ikm, "Content-Encoding: nonce\0", 12)

    # RFC 8188 §2: content || 0x02 delimiter (final record).
    padded = plaintext <> <<2>>
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, padded, "", true)

    rs = <<4096::unsigned-big-32>>
    salt <> rs <> <<byte_size(server_public)>> <> server_public <> ciphertext <> tag
  end

  ## Delivery

  @doc """
  Delivers `payload` (a JSON string) to one subscription.

  Returns `:ok` on 2xx; `{:error, :gone}` after soft-deleting a `404`/`410` subscription;
  `{:error, :vapid_not_configured}` / `{:error, :vapid_decrypt_failed}` when keys are missing
  or unreadable; `{:error, reason}` otherwise.
  """
  def send_web_push(%PushSubscription{} = subscription, payload) when is_binary(payload) do
    with {:ok, public_key_b64, private_key} <- load_vapid_keys() do
      encrypted = encrypt(payload, subscription.p256dh, subscription.auth)

      headers =
        Vapid.authorization_headers(subscription.endpoint, public_key_b64, private_key, subject()) ++
          [
            {"content-type", "application/octet-stream"},
            {"content-encoding", "aes128gcm"},
            {"content-length", Integer.to_string(byte_size(encrypted))}
          ]

      case SafeClient.post(subscription.endpoint, encrypted, headers) do
        {:ok, status, _headers} when status in 200..299 ->
          :ok

        {:ok, status, _headers} when status in [404, 410] ->
          soft_delete(subscription)
          {:error, :gone}

        {:ok, status, _headers} ->
          Logger.warning("Web push failed: HTTP #{status} for #{endpoint_label(subscription)}")
          {:error, {:http_error, status}}

        {:error, reason} ->
          Logger.warning("Web push error: #{inspect(reason)} for #{endpoint_label(subscription)}")
          {:error, reason}
      end
    end
  end

  # A log-safe label for a subscription: its id plus only the push-service host. The full
  # endpoint URL embeds a per-subscription registration token (a delivery capability), so it
  # must never reach the logs.
  defp endpoint_label(subscription) do
    host =
      case URI.parse(subscription.endpoint || "") do
        %URI{host: h} when is_binary(h) -> h
        _ -> "unknown"
      end

    "subscription ##{subscription.id} (#{host})"
  end

  @doc """
  Builds the JSON-encodable payload for a notification.

  Reuses the Stage-1 bell renderers (`Goodmao2Web.Helpers`) so push copy matches the in-site
  copy and links to the same target. Rendered in the default locale (there is no per-request
  locale in the dispatch worker).
  """
  def build_payload(%Notification{} = notification) do
    %{
      title: Goodmao2Web.Helpers.notification_title(notification),
      body: Goodmao2Web.Helpers.notification_summary(notification) || "",
      url: notification_url(notification),
      type: notification.type,
      icon: nil
    }
  end

  ## Private

  defp load_vapid_keys do
    public_key_b64 = Settings.get(@public_key_setting)
    encrypted_private = Settings.get(@private_key_setting)

    cond do
      is_nil(public_key_b64) or is_nil(encrypted_private) ->
        {:error, :vapid_not_configured}

      true ->
        case VapidVault.decrypt(Base.decode64!(encrypted_private)) do
          {:ok, private_key} -> {:ok, public_key_b64, private_key}
          :error -> {:error, :vapid_decrypt_failed}
        end
    end
  end

  defp notification_url(notification) do
    base = Goodmao2Web.Endpoint.url()

    case Goodmao2Web.Helpers.notification_path(notification) do
      nil -> base <> "/notifications"
      path -> base <> path
    end
  end

  defp soft_delete(%PushSubscription{} = subscription) do
    subscription
    |> Ecto.Changeset.change(deleted_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update()
  end

  # HKDF-SHA256 extract-and-expand.
  defp hkdf_sha256(salt, ikm, info, length) do
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    hkdf_expand(prk, info, length, 1, <<>>, <<>>)
  end

  defp hkdf_expand(_prk, _info, length, _counter, _prev, acc) when byte_size(acc) >= length do
    binary_part(acc, 0, length)
  end

  defp hkdf_expand(prk, info, length, counter, prev, acc) do
    t = :crypto.mac(:hmac, :sha256, prk, prev <> info <> <<counter>>)
    hkdf_expand(prk, info, length, counter + 1, t, acc <> t)
  end
end
