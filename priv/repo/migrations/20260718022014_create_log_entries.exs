defmodule Goodmao2.Repo.Migrations.CreateLogEntries do
  use Ecto.Migration

  def change do
    create table(:log_entries) do
      add :pet_id, references(:pets, on_delete: :delete_all), null: false

      # Who logged it — audit only, no FK (owner, co-caretaker, or vet).
      add :recorded_by_user_id, references(:users, on_delete: :nilify_all)

      # The discriminator: food | water | bathroom | vomit | weight | energy |
      # medication | symptom | vet_note | life. One table, strongly-typed subtypes.
      add :type, :string, null: false

      # When the event happened (may differ from when it was entered).
      add :occurred_at, :utc_datetime, null: false

      # Free-text note, alongside the structured fields — never instead of them.
      add :note, :text

      # private | limited | public — who may read the entry. Owners are the only
      # role that can change it.
      add :visibility, :string, null: false, default: "limited"

      # The strongly-typed structured payload for the subtype (amount, count,
      # weight_grams, level, etc.) plus species-specific overflow. jsonb so the
      # schema generalizes beyond cats without a migration per species.
      add :data, :map, null: false, default: %{}

      # Soft-delete marker. Null = live; set = deleted. A row is preserved on delete;
      # reads filter on `deleted_at IS NULL`.
      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # The timeline query: a pet's live entries, newest first, optionally by type.
    create index(:log_entries, [:pet_id, :occurred_at])
    create index(:log_entries, [:pet_id, :type])
    create index(:log_entries, [:deleted_at])
  end
end
