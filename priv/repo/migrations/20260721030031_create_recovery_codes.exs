defmodule Goodmao2.Repo.Migrations.CreateRecoveryCodes do
  use Ecto.Migration

  def change do
    create table(:recovery_codes) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      # HMAC-SHA256 of the recovery code (keyed off SECRET_KEY_BASE). The raw code is
      # shown once at generation and NEVER stored.
      add :code_hash, :binary, null: false
      # Single-use marker; stamped atomically when the code is consumed.
      add :used_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:recovery_codes, [:user_id])
  end
end
