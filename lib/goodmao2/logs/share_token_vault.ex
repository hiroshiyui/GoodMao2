defmodule Goodmao2.Logs.ShareTokenVault do
  @moduledoc """
  Keeps a `public` log entry's share token recoverable for its owner but useless to anyone
  holding only the database (ADR-0004).

  The token is stored twice and never in the clear: as its SHA-256 (`share_token_hash`, what
  the anonymous read path looks up — as report share links already are) and AES-256-GCM
  encrypted (`share_token_encrypted`, decrypted only to show the owner the link to copy). A
  leaked backup or replica therefore yields no working link without `SECRET_KEY_BASE` as well.

  Same construction as `Goodmao2.Accounts.TotpVault`: a 32-byte key derived from the
  endpoint's `secret_key_base` (PBKDF2, salt `"log_share_token_key"`), the module name as AAD,
  stored as `<<iv::12, tag::16, ciphertext::rest>>`. Rotating `SECRET_KEY_BASE` leaves every
  link working (lookup is by hash) but hides it from the owner's copy button until the entry is
  re-published.
  """

  @aad "Goodmao2.Logs.ShareTokenVault"

  @doc "The lookup digest of a raw share token."
  def hash(token) when is_binary(token), do: :crypto.hash(:sha256, token)

  @doc "Encrypts a raw share token, returning `<<iv::12, tag::16, ciphertext::rest>>`."
  def encrypt(token) when is_binary(token) do
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, derive_key(), iv, token, @aad, true)

    iv <> tag <> ciphertext
  end

  @doc "Decrypts a blob from `encrypt/1`: `{:ok, token}`, or `:error` (wrong key, tampered, malformed)."
  def decrypt(<<iv::binary-12, tag::binary-16, ciphertext::binary>>) do
    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           derive_key(),
           iv,
           ciphertext,
           @aad,
           tag,
           false
         ) do
      token when is_binary(token) -> {:ok, token}
      :error -> :error
    end
  end

  def decrypt(_), do: :error

  defp derive_key do
    secret_key_base = Application.get_env(:goodmao2, Goodmao2Web.Endpoint)[:secret_key_base]
    Plug.Crypto.KeyGenerator.generate(secret_key_base, "log_share_token_key", length: 32)
  end
end
