defmodule Goodmao2.Medications.Dose do
  @moduledoc """
  One durable dose slot materialized from a `Medications.Schedule` (ADR-0019).

  A row per expected dose is the coordination core of "did anyone give the pill?": any caretaker
  can see whether *this* slot is already handled and by whom. `due_at` is the slot instant in UTC
  (computed from the schedule's wall-clock time + `timezone`). `status` moves
  `pending → given | skipped | missed`; `given` also stamps `given_at`, `recorded_by_user_id`,
  and `log_entry_id` (the `medication` `log_entry` created for the timeline). `pet_id` is the
  denormalized authorization anchor. `reminded_at` de-dupes the due reminder.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending given skipped missed)

  def statuses, do: @statuses

  schema "medication_doses" do
    # Denormalized authorization anchor (mirrors media_assets) — no belongs_to.
    field :pet_id, :id
    field :due_at, :utc_datetime
    field :status, :string, default: "pending"
    field :given_at, :utc_datetime
    # Audit-only ids — no belongs_to.
    field :recorded_by_user_id, :id
    field :log_entry_id, :id
    field :reminded_at, :utc_datetime

    belongs_to :schedule, Goodmao2.Medications.Schedule

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for status transitions (given/skipped/missed) and reminder stamping."
  def changeset(dose, attrs) do
    dose
    |> cast(attrs, [:status, :given_at, :recorded_by_user_id, :log_entry_id, :reminded_at])
    |> validate_inclusion(:status, @statuses)
  end
end
