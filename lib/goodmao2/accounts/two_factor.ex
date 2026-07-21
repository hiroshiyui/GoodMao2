defmodule Goodmao2.Accounts.TwoFactor do
  @moduledoc """
  TOTP two-factor authentication and one-time recovery codes (ADR-0013).

  The public API is re-exported through `Goodmao2.Accounts`; the web layer calls
  `Accounts.*`, never this module directly.

  ## TOTP

  The shared secret is stored **encrypted** in `users.totp_secret` via
  `Goodmao2.Accounts.TotpVault` — the raw secret never touches the database.
  `users.totp_confirmed_at` is set only once the user proves possession with a valid
  code; a nil value means TOTP is not enabled.

  ## Recovery codes

  Ten single-use codes back up TOTP (for a lost authenticator). Only their HMAC-SHA256
  hashes are stored; the raw codes are shown once at generation. They are tied to TOTP
  enrollment — regenerated on demand and cleared when TOTP is disabled.

  ## Login state machine

  `login_next_step/1` decides what must happen after primary authentication
  (magic-link or password) succeeds — see `Goodmao2Web.UserSessionController`.
  """

  import Ecto.Query, warn: false

  alias Goodmao2.Repo
  alias Goodmao2.Accounts.{RecoveryCode, TotpVault, User, WebAuthn}

  @issuer "GoodMao"
  @recovery_code_count 10

  # ---------------------------------------------------------------------------
  # State
  # ---------------------------------------------------------------------------

  @doc "Returns true if the user has confirmed a TOTP authenticator."
  @spec totp_enabled?(User.t()) :: boolean()
  def totp_enabled?(%User{totp_confirmed_at: nil}), do: false
  def totp_enabled?(%User{}), do: true

  @doc """
  Determines what must happen after primary authentication succeeds.

    * `:challenge` — the user has a second factor (TOTP or a security key) and must
      pass it before a session is issued.
    * `:setup_required` — the user is *required* to have a second factor (the admin) but
      has none enrolled yet; they are forced into setup before reaching the app.
    * `:authenticated` — no second factor needed; issue the session immediately.

  The admin (the sole global role) is the only account for which a second factor is
  mandatory; every other user opts in.
  """
  @spec login_next_step(User.t()) :: :challenge | :setup_required | :authenticated
  def login_next_step(%User{} = user) do
    cond do
      totp_enabled?(user) or WebAuthn.webauthn_enabled?(user) -> :challenge
      user.is_admin -> :setup_required
      true -> :authenticated
    end
  end

  # ---------------------------------------------------------------------------
  # TOTP
  # ---------------------------------------------------------------------------

  @doc "Generates a new random TOTP secret."
  @spec generate_totp_secret() :: binary()
  def generate_totp_secret, do: NimbleTOTP.secret()

  @doc "Builds an `otpauth://` URI for QR-code enrollment."
  @spec totp_uri(binary(), String.t()) :: String.t()
  def totp_uri(secret, account_name) do
    NimbleTOTP.otpauth_uri("#{@issuer}:#{account_name}", secret, issuer: @issuer)
  end

  @doc "Renders an `otpauth://` URI as an inline base64 SVG data URI for display."
  @spec totp_qr_data_uri(String.t()) :: String.t()
  def totp_qr_data_uri(uri) do
    svg = uri |> EQRCode.encode() |> EQRCode.svg(width: 264)
    "data:image/svg+xml;base64," <> Base.encode64(svg)
  end

  @doc """
  Validates a TOTP `code` against a raw `secret`.

  Pass `since:` (a unix timestamp or `DateTime`) to reject codes from the same or an
  earlier 30-second window — replay protection against reusing a just-used code.
  """
  @spec valid_totp?(binary(), String.t(), keyword()) :: boolean()
  def valid_totp?(secret, code, opts \\ []) when is_binary(secret) and is_binary(code) do
    nimble_opts =
      case Keyword.get(opts, :since) do
        nil -> []
        ts when is_integer(ts) -> [since: DateTime.from_unix!(ts)]
        %DateTime{} = dt -> [since: dt]
      end

    NimbleTOTP.valid?(secret, code, nimble_opts)
  end

  @doc """
  Enables TOTP for `user`: encrypts `secret` via `TotpVault` and stamps
  `totp_confirmed_at`. The raw secret is never persisted.
  """
  @spec enable_totp(User.t(), binary()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def enable_totp(%User{} = user, secret) when is_binary(secret) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    user
    |> User.totp_changeset(%{totp_secret: TotpVault.encrypt(secret), totp_confirmed_at: now})
    |> Repo.update()
  end

  @doc "Decrypts and returns the user's raw TOTP secret, or nil if unset/undecryptable."
  @spec decrypt_totp_secret(User.t()) :: binary() | nil
  def decrypt_totp_secret(%User{totp_secret: nil}), do: nil

  def decrypt_totp_secret(%User{totp_secret: encrypted}) do
    case TotpVault.decrypt(encrypted) do
      {:ok, secret} -> secret
      :error -> nil
    end
  end

  @doc """
  Disables TOTP for `user`: clears the encrypted secret and `totp_confirmed_at`, and
  deletes the user's recovery codes (they exist only to back up TOTP).
  """
  @spec disable_totp(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def disable_totp(%User{} = user) do
    with {:ok, user} <-
           user
           |> User.totp_changeset(%{totp_secret: nil, totp_confirmed_at: nil})
           |> Repo.update() do
      delete_recovery_codes(user)
      {:ok, user}
    end
  end

  # ---------------------------------------------------------------------------
  # Recovery codes
  # ---------------------------------------------------------------------------

  @doc """
  Generates a fresh set of #{@recovery_code_count} one-time recovery codes for `user`.

  Deletes any existing codes, stores only the HMAC-SHA256 hashes, and returns the raw
  formatted codes (`xxxx-xxxx`) for one-time display — they cannot be recovered later.
  """
  @spec generate_recovery_codes(User.t()) :: [String.t()]
  def generate_recovery_codes(%User{} = user) do
    delete_recovery_codes(user)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    raw_codes =
      Enum.map(1..@recovery_code_count, fn _ ->
        :crypto.strong_rand_bytes(5) |> Base.encode32(case: :lower, padding: false)
      end)

    entries =
      Enum.map(raw_codes, fn code ->
        %{user_id: user.id, code_hash: hmac_recovery_code(code), inserted_at: now}
      end)

    Repo.insert_all(RecoveryCode, entries)

    Enum.map(raw_codes, &format_recovery_code/1)
  end

  @doc "Returns the number of unused recovery codes the user has remaining."
  @spec recovery_codes_remaining(User.t()) :: non_neg_integer()
  def recovery_codes_remaining(%User{} = user) do
    Repo.aggregate(
      from(rc in RecoveryCode, where: rc.user_id == ^user.id and is_nil(rc.used_at)),
      :count
    )
  end

  @doc """
  Verifies and consumes a recovery `code` for `user`.

  Normalizes the input, computes its HMAC, and atomically stamps `used_at` on the
  matching unused row via `Repo.update_all` (TOCTOU-safe). Returns `:ok` if exactly one
  code was consumed, `:error` otherwise.
  """
  @spec verify_recovery_code(User.t(), String.t() | any()) :: :ok | :error
  def verify_recovery_code(%User{} = user, code) when is_binary(code) do
    code_hash = hmac_recovery_code(normalize_recovery_code(code))
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    query =
      from(rc in RecoveryCode,
        where: rc.user_id == ^user.id and rc.code_hash == ^code_hash and is_nil(rc.used_at)
      )

    case Repo.update_all(query, set: [used_at: now]) do
      {1, _} -> :ok
      {0, _} -> :error
    end
  end

  def verify_recovery_code(_, _), do: :error

  defp delete_recovery_codes(%User{} = user) do
    Repo.delete_all(from rc in RecoveryCode, where: rc.user_id == ^user.id)
  end

  defp normalize_recovery_code(code) do
    code |> String.trim() |> String.downcase() |> String.replace("-", "")
  end

  defp format_recovery_code(code) do
    String.slice(code, 0, 4) <> "-" <> String.slice(code, 4, 4)
  end

  defp hmac_recovery_code(code) do
    :crypto.mac(:hmac, :sha256, recovery_code_hmac_key(), code)
  end

  defp recovery_code_hmac_key do
    secret_key_base = Application.get_env(:goodmao2, Goodmao2Web.Endpoint)[:secret_key_base]

    Plug.Crypto.KeyGenerator.generate(secret_key_base, "recovery_code_hmac_key", length: 32)
  end
end
