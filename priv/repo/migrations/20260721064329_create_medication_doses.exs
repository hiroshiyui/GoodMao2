defmodule Goodmao2.Repo.Migrations.CreateMedicationDoses do
  use Ecto.Migration

  def change do
    # One durable slot per expected dose (ADR-0019). Materialized from the schedule so any
    # caretaker can see whether *this* slot is already handled and by whom — the coordination core.
    create table(:medication_doses) do
      add :schedule_id, references(:medication_schedules, on_delete: :delete_all), null: false
      # Denormalized authorization anchor (mirrors media_assets) — no belongs_to.
      add :pet_id, references(:pets, on_delete: :delete_all), null: false

      # The slot instant, in UTC (computed from the schedule's wall-clock time + timezone).
      add :due_at, :utc_datetime, null: false
      # pending | given | skipped | missed
      add :status, :string, null: false, default: "pending"

      add :given_at, :utc_datetime
      # Who gave/skipped it — audit only, no FK navigation.
      add :recorded_by_user_id, references(:users, on_delete: :nilify_all)
      # The `medication` log_entry created when the dose was given (audit link, no navigation).
      add :log_entry_id, references(:log_entries, on_delete: :nilify_all)

      # Stamped when a due reminder was sent, so the sweep nudges once, not every tick.
      add :reminded_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # Idempotent materialization: never generate the same slot twice.
    create unique_index(:medication_doses, [:schedule_id, :due_at])
    create index(:medication_doses, [:pet_id, :due_at])
    # The reminder/missed sweep only cares about pending slots.
    create index(:medication_doses, [:due_at],
             where: "status = 'pending'",
             name: :medication_doses_pending_index
           )
  end
end
