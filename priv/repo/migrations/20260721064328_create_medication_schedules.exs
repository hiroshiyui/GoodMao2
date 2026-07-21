defmodule Goodmao2.Repo.Migrations.CreateMedicationSchedules do
  use Ecto.Migration

  def change do
    # A recurring medication plan for a pet (ADR-0019). Dose times are wall-clock in the
    # schedule's own `timezone`; the durable dose slots (medication_doses) are computed from it.
    create table(:medication_schedules) do
      add :pet_id, references(:pets, on_delete: :delete_all), null: false

      add :medication_name, :string, null: false
      add :dose, :string, null: false

      # Daily dose times (≥1), e.g. {08:00, 20:00} — wall-clock in `timezone`.
      add :times_of_day, {:array, :time}, null: false, default: []
      # Every N days (1 = daily).
      add :interval_days, :integer, null: false, default: 1

      add :start_date, :date, null: false
      # Nil = open-ended course.
      add :end_date, :date

      # IANA zone the dose times are interpreted in (validated in the app against the tz db).
      add :timezone, :string, null: false

      # Pause without deleting.
      add :active, :boolean, null: false, default: true
      add :notes, :text

      # Who created it — audit only, no FK navigation (the house pattern).
      add :created_by_user_id, references(:users, on_delete: :nilify_all)

      # Soft-delete marker (null = live).
      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:medication_schedules, [:pet_id])
    # The materialization sweep scans live, active schedules.
    create index(:medication_schedules, [:active, :deleted_at])
  end
end
