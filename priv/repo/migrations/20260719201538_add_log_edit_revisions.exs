defmodule Goodmao2.Repo.Migrations.AddLogEditRevisions do
  use Ecto.Migration

  def change do
    alter table(:log_entries) do
      # Denormalized 0–9 edit counter: an O(1) cap check and the "N of 9" UI (ADR-0009).
      add :edit_count, :integer, null: false, default: 0
    end

    create table(:log_entry_revisions) do
      add :log_entry_id, references(:log_entries, on_delete: :delete_all), null: false

      # Denormalized pet scope, mirroring log_entries.pet_id for integrity (ADR-0009).
      add :pet_id, references(:pets, on_delete: :delete_all), null: false

      # Who made the edit — audit only, no schema navigation (like recorded_by_user_id).
      add :edited_by_user_id, references(:users, on_delete: :nilify_all)

      # Immutable jsonb snapshot of the entry as it stood *before* the edit: type, data,
      # note, occurred_at, visibility. The unlisted share token is never snapshotted.
      add :snapshot, :map, null: false, default: %{}

      # Immutable: only an insert time, never updated.
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:log_entry_revisions, [:log_entry_id])
  end
end
