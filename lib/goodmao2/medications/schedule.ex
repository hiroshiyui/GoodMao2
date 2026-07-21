defmodule Goodmao2.Medications.Schedule do
  @moduledoc """
  A recurring medication plan for a pet (ADR-0019).

  Dose times (`times_of_day`) are **wall-clock in the schedule's own `timezone`** — "8am" is the
  pet's local 8am, shared across caretakers who may be in different zones. The durable dose slots
  (`Medications.Dose`) are materialized from this plan by converting each time in `timezone` to a
  UTC instant. Soft-deleted via `deleted_at`; `active: false` pauses without deleting.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "medication_schedules" do
    field :medication_name, :string
    field :dose, :string
    field :times_of_day, {:array, :time}, default: []
    field :interval_days, :integer, default: 1
    field :start_date, :date
    field :end_date, :date
    field :timezone, :string
    field :active, :boolean, default: true
    field :notes, :string

    # Audit-only — no belongs_to (avoids extra cascade paths).
    field :created_by_user_id, :id
    field :deleted_at, :utc_datetime

    belongs_to :pet, Goodmao2.Pets.Pet
    has_many :doses, Goodmao2.Medications.Dose

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or editing a schedule.

  `timezone` defaults to the caller's active zone at the LiveView boundary; both `timezone` and
  each `times_of_day` entry are validated, and `end_date` (when present) must not precede
  `start_date`.
  """
  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, [
      :pet_id,
      :medication_name,
      :dose,
      :times_of_day,
      :interval_days,
      :start_date,
      :end_date,
      :timezone,
      :active,
      :notes
    ])
    |> validate_required([
      :pet_id,
      :medication_name,
      :dose,
      :times_of_day,
      :start_date,
      :timezone
    ])
    |> validate_length(:medication_name, max: 200)
    |> validate_length(:dose, max: 200)
    |> validate_length(:notes, max: 2000)
    |> validate_number(:interval_days, greater_than_or_equal_to: 1, less_than_or_equal_to: 365)
    |> validate_at_least_one_time()
    |> validate_timezone()
    |> validate_date_order()
  end

  defp validate_at_least_one_time(changeset) do
    case get_field(changeset, :times_of_day) do
      [_ | _] -> changeset
      _ -> add_error(changeset, :times_of_day, "needs at least one dose time")
    end
  end

  defp validate_timezone(changeset) do
    case get_change(changeset, :timezone) do
      nil ->
        changeset

      tz ->
        if Goodmao2.Timezone.known?(tz),
          do: changeset,
          else: add_error(changeset, :timezone, "is not a valid timezone")
    end
  end

  defp validate_date_order(changeset) do
    start = get_field(changeset, :start_date)
    finish = get_field(changeset, :end_date)

    if start && finish && Date.compare(finish, start) == :lt do
      add_error(changeset, :end_date, "cannot be before the start date")
    else
      changeset
    end
  end
end
