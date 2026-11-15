defmodule Goodmao2.Repo.Migrations.HashAndEncryptLogEntryShareTokens do
  use Ecto.Migration

  # A public entry's share token was stored in the clear, so a leaked backup or replica held a
  # working anonymous link to every public entry and its media. It is now stored as its SHA-256
  # (the lookup, as report links already are) and AES-GCM encrypted under `SECRET_KEY_BASE`
  # (only to show the owner the link again). Existing links are carried over, so every link
  # already handed out keeps working.
  #
  # The backfill uses `Goodmao2.Logs.ShareTokenVault`, so it needs the endpoint's
  # `secret_key_base` in config — present under `mix ecto.migrate` and in `Release.migrate`
  # (runtime config is applied before `eval`).

  alias Goodmao2.Logs.ShareTokenVault

  def up do
    alter table(:log_entries) do
      add :share_token_hash, :binary
      add :share_token_encrypted, :binary
    end

    flush()

    %{rows: rows} =
      repo().query!("SELECT id, share_token FROM log_entries WHERE share_token IS NOT NULL")

    for [id, token] <- rows do
      repo().query!(
        "UPDATE log_entries SET share_token_hash = $1, share_token_encrypted = $2 WHERE id = $3",
        [ShareTokenVault.hash(token), ShareTokenVault.encrypt(token), id]
      )
    end

    drop_if_exists index(:log_entries, [:share_token])

    alter table(:log_entries) do
      remove :share_token
    end

    create unique_index(:log_entries, [:share_token_hash], where: "share_token_hash IS NOT NULL")
  end

  def down do
    alter table(:log_entries) do
      add :share_token, :string
    end

    flush()

    %{rows: rows} =
      repo().query!(
        "SELECT id, share_token_encrypted FROM log_entries WHERE share_token_encrypted IS NOT NULL"
      )

    for [id, blob] <- rows, {:ok, token} <- [ShareTokenVault.decrypt(blob)] do
      repo().query!("UPDATE log_entries SET share_token = $1 WHERE id = $2", [token, id])
    end

    drop_if_exists index(:log_entries, [:share_token_hash])

    alter table(:log_entries) do
      remove :share_token_hash
      remove :share_token_encrypted
    end

    create unique_index(:log_entries, [:share_token], where: "share_token IS NOT NULL")
  end
end
