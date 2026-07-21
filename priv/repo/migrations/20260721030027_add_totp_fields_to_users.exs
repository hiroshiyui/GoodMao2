defmodule Goodmao2.Repo.Migrations.AddTotpFieldsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # AES-256-GCM ciphertext of the TOTP shared secret (see Accounts.TotpVault).
      # The raw secret is NEVER stored — only the encrypted blob.
      add :totp_secret, :binary
      # When TOTP was confirmed by entering a valid code. Nil ⇒ TOTP not enabled.
      add :totp_confirmed_at, :utc_datetime
    end
  end
end
