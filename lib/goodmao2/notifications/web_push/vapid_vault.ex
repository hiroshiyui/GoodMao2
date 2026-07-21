defmodule Goodmao2.Notifications.WebPush.VapidVault do
  @moduledoc """
  Encrypts and decrypts the VAPID private key at rest using AES-256-GCM.

  The key is derived from the endpoint's `secret_key_base` via `Plug.Crypto.KeyGenerator`
  (PBKDF2) with the salt `"vapid_key_encryption"`, producing a 32-byte AES-256 key. So the
  effective secret backing the VAPID private key is `SECRET_KEY_BASE` — **rotating it makes
  the stored key undecryptable**, at which point an admin must regenerate the keypair on
  `/admin/settings` (which invalidates existing browser subscriptions).

  ## Storage format

      <<iv::12, tag::16, ciphertext::rest>>

  ## AAD

  The module name is used as additional authenticated data, binding a ciphertext to this
  purpose — it will not decrypt under the same key in a different context.
  """

  @aad "Goodmao2.Notifications.WebPush.VapidVault"

  @doc "Encrypts `plaintext`, returning `<<iv::12, tag::16, ciphertext::rest>>`."
  def encrypt(plaintext) when is_binary(plaintext) do
    key = derive_key()
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, @aad, true)

    iv <> tag <> ciphertext
  end

  @doc """
  Decrypts a blob previously produced by `encrypt/1`.

  Returns `{:ok, plaintext}`, or `:error` on any failure (wrong key, tampered data, or a
  malformed blob).
  """
  def decrypt(<<iv::binary-12, tag::binary-16, ciphertext::binary>>) do
    key = derive_key()

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, @aad, tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      :error -> :error
    end
  end

  def decrypt(_), do: :error

  defp derive_key do
    secret_key_base = Application.get_env(:goodmao2, Goodmao2Web.Endpoint)[:secret_key_base]

    Plug.Crypto.KeyGenerator.generate(secret_key_base, "vapid_key_encryption", length: 32)
  end
end
