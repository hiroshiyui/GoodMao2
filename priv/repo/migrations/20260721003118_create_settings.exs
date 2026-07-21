defmodule Goodmao2.Repo.Migrations.CreateSettings do
  use Ecto.Migration

  def change do
    # A tiny global key/value store for site-wide system settings an administrator
    # manages from the Web UI (first occupant: the Web Push VAPID keypair). Values are
    # opaque strings; a secret value (e.g. the VAPID private key) is encrypted by the
    # writer before it lands here — the table itself makes no confidentiality promise.
    create table(:settings) do
      add :key, :string, null: false
      add :value, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:settings, [:key])
  end
end
