defmodule Goodmao2.Medications do
  @moduledoc """
  The Medications context: recurring medication **schedules**, their durable **dose** slots, and
  the "did anyone give the pill?" coordination (ADR-0019).

  Authorization is resource-based, delegated to `Pets` (ADR-0014): reading a pet's schedules/doses
  needs `:read`; creating/editing a schedule and marking a dose given/skipped need `:write` (owner,
  co-caretaker, vet); deleting a schedule needs `:manage` (owner). Inaccessible pets are
  existence-hidden.

  Dose slots are **materialized** from each schedule in the schedule's own timezone (see
  `Goodmao2.Timezone`), so any caretaker can see whether a specific slot is handled and reminders
  fire at the right local instant. Marking a dose given reuses the `medication` `log_entry`
  (`Goodmao2.Logs`) — no parallel history.
  """
  import Ecto.Query, warn: false

  alias Goodmao2.Repo
  alias Goodmao2.Pets
  alias Goodmao2.Pets.Pet
  alias Goodmao2.Logs
  alias Goodmao2.Accounts.User
  alias Goodmao2.Medications.{Schedule, Dose}

  # How far ahead dose slots are pre-created. The cron sweep runs often enough to keep this
  # window filled as time rolls forward.
  @horizon_hours 48

  # A pending dose is marked `missed` once it is this many hours past due with no action.
  @missed_grace_hours 2

  ## Schedules

  @doc "Lists a pet's live schedules (newest first). Requires `:read`; `[]` if not permitted."
  def list_schedules(%User{} = user, %Pet{} = pet) do
    if Pets.can?(pet, user, :read) do
      Repo.all(
        from s in Schedule,
          where: s.pet_id == ^pet.id and is_nil(s.deleted_at),
          order_by: [desc: s.active, desc: s.inserted_at, desc: s.id]
      )
    else
      []
    end
  end

  @doc """
  Fetches one live schedule the user may read, or `nil` (existence-hidden) when it is absent or
  the caller lacks `:read` on the pet.
  """
  def get_schedule(%User{} = user, %Pet{} = pet, id) do
    if Pets.can?(pet, user, :read) do
      Repo.one(
        from s in Schedule,
          where: s.id == ^id and s.pet_id == ^pet.id and is_nil(s.deleted_at)
      )
    else
      nil
    end
  end

  @doc "Changeset for the schedule form."
  def change_schedule(%Schedule{} = schedule, attrs \\ %{}),
    do: Schedule.changeset(schedule, attrs)

  ## Doses (coordination reads)

  @doc """
  Lists a pet's dose slots around now — recent (default 24h back, for overdue/just-done) through
  the materialization horizon — with the parent schedule preloaded, oldest-due first. Requires
  `:read`; `[]` otherwise. Doses of soft-deleted schedules are excluded.
  """
  def upcoming_doses(%User{} = user, %Pet{} = pet, opts \\ []) do
    if Pets.can?(pet, user, :read) do
      from_dt = Keyword.get(opts, :from, DateTime.add(now(), -24, :hour))
      to_dt = Keyword.get(opts, :to, DateTime.add(now(), @horizon_hours, :hour))

      Repo.all(
        from d in Dose,
          join: s in Schedule,
          on: s.id == d.schedule_id,
          where: d.pet_id == ^pet.id and is_nil(s.deleted_at),
          where: d.due_at >= ^from_dt and d.due_at <= ^to_dt,
          order_by: [asc: d.due_at],
          preload: [schedule: s]
      )
    else
      []
    end
  end

  @doc """
  Creates a schedule for a pet and materializes its upcoming dose slots. Requires `:write`.
  """
  def create_schedule(%User{} = user, %Pet{} = pet, attrs) do
    with :ok <- authorize(pet, user, :write) do
      attrs = Map.put(string_keys(attrs), "pet_id", pet.id)

      changeset =
        %Schedule{created_by_user_id: user.id}
        |> Schedule.changeset(attrs)

      with {:ok, schedule} <- Repo.insert(changeset) do
        materialize_doses(schedule)
        {:ok, schedule}
      end
    end
  end

  @doc """
  Updates a schedule. Requires `:write`. When the timing (times/interval/dates/zone/active)
  changes, future `pending` doses are regenerated from the new plan.
  """
  def update_schedule(%User{} = user, %Pet{} = pet, %Schedule{} = schedule, attrs) do
    with :ok <- authorize(pet, user, :write),
         {:ok, updated} <- schedule |> Schedule.changeset(string_keys(attrs)) |> Repo.update() do
      if timing_changed?(schedule, updated) do
        drop_future_pending_doses(updated)
        materialize_doses(updated)
      end

      {:ok, updated}
    end
  end

  @doc """
  Pauses or resumes a schedule (`active`). Requires `:write`. Pausing drops future pending doses;
  resuming re-materializes them.
  """
  def set_active(%User{} = user, %Pet{} = pet, %Schedule{} = schedule, active?)
      when is_boolean(active?) do
    with :ok <- authorize(pet, user, :write),
         {:ok, updated} <-
           schedule |> Schedule.changeset(%{"active" => active?}) |> Repo.update() do
      if active?, do: materialize_doses(updated), else: drop_future_pending_doses(updated)
      {:ok, updated}
    end
  end

  @doc """
  Soft-deletes a schedule and cancels its future pending doses. Requires `:manage` (owner).
  """
  def delete_schedule(%User{} = user, %Pet{} = pet, %Schedule{} = schedule) do
    with :ok <- authorize(pet, user, :manage) do
      drop_future_pending_doses(schedule)

      schedule
      |> Ecto.Changeset.change(deleted_at: now())
      |> Repo.update()
    end
  end

  ## Cron sweep (called by Medications.ReminderWorker)

  @write_roles ~w(owner co_caretaker vet)

  @doc "Materializes upcoming dose slots for every live, active schedule. Returns `:ok`."
  def materialize_due_doses do
    Repo.all(from s in Schedule, where: s.active == true and is_nil(s.deleted_at))
    |> Enum.each(&materialize_doses/1)

    :ok
  end

  @doc """
  Sends a `medication_due` reminder (bell + Web Push) for every pending, unreminded dose that is
  now due, then stamps `reminded_at` so it nudges once. Recipients are the pet's effective
  caretakers who can write (owner / co-caretaker / vet). Returns `{:ok, sent}` (dose count).
  """
  def dispatch_due_reminders do
    due =
      Repo.all(
        from d in Dose,
          join: s in Schedule,
          on: s.id == d.schedule_id,
          where: s.active == true and is_nil(s.deleted_at),
          where: d.status == "pending" and is_nil(d.reminded_at) and d.due_at <= ^now(),
          preload: [schedule: s]
      )

    Enum.each(due, &remind_one/1)
    {:ok, length(due)}
  end

  defp remind_one(%Dose{} = dose) do
    pet = Repo.get(Pet, dose.pet_id)
    schedule = dose.schedule

    payload = %{
      "pet_id" => pet.id,
      "pet_name" => pet.name,
      "schedule_id" => schedule.id,
      "dose_id" => dose.id,
      "medication_name" => schedule.medication_name,
      "dose" => schedule.dose,
      "due_at" => DateTime.to_iso8601(dose.due_at)
    }

    pet
    |> Pets.list_effective_accesses()
    |> Enum.filter(&(&1.role in @write_roles))
    |> Enum.map(& &1.user_id)
    |> Enum.uniq()
    |> Enum.each(&Goodmao2.Notifications.create(&1, "medication_due", payload))

    # Stamp so the next sweep doesn't re-nudge this slot.
    Repo.update_all(from(d in Dose, where: d.id == ^dose.id), set: [reminded_at: now()])
    :ok
  end

  ## Claiming a dose

  @doc """
  Marks a pending dose **given** by `user`: reuses the `medication` `log_entry` for the timeline
  and stamps the dose. Requires `:write`.

  The claim is TOCTOU-safe — an atomic `pending → given` transition means two caretakers racing to
  record the same dose can't both succeed; the loser gets `{:error, :already_recorded}`. The log
  entry and the dose stamp commit together (or not at all).
  """
  def mark_dose_given(%User{} = user, %Pet{} = pet, %Dose{} = dose, attrs \\ %{}) do
    with :ok <- authorize(pet, user, :write) do
      schedule = Repo.get(Schedule, dose.schedule_id)
      given_at = now()

      Repo.transact(fn ->
        # Atomic claim: only a still-pending dose can be given.
        {claimed, _} =
          Repo.update_all(
            from(d in Dose, where: d.id == ^dose.id and d.status == "pending"),
            set: [status: "given", updated_at: given_at]
          )

        if claimed == 1 do
          log_attrs = %{
            "type" => "medication",
            "data" => %{"medication_name" => schedule.medication_name, "dose" => schedule.dose},
            "occurred_at" => given_at,
            "note" => attrs["note"] || attrs[:note]
          }

          with {:ok, entry} <- Logs.create_entry(user, pet, log_attrs) do
            Repo.update_all(
              from(d in Dose, where: d.id == ^dose.id),
              set: [
                given_at: given_at,
                recorded_by_user_id: user.id,
                log_entry_id: entry.id,
                updated_at: given_at
              ]
            )

            {:ok, Repo.get(Dose, dose.id)}
          end
        else
          {:error, :already_recorded}
        end
      end)
      |> tap_broadcast(pet)
    end
  end

  @doc """
  Marks a pending dose **skipped** (e.g. a vet said hold it). Requires `:write`. No log entry is
  created. Same atomic claim as `mark_dose_given/4`.
  """
  def mark_dose_skipped(%User{} = user, %Pet{} = pet, %Dose{} = dose) do
    with :ok <- authorize(pet, user, :write) do
      {claimed, _} =
        Repo.update_all(
          from(d in Dose, where: d.id == ^dose.id and d.status == "pending"),
          set: [status: "skipped", recorded_by_user_id: user.id, updated_at: now()]
        )

      if claimed == 1 do
        {:ok, Repo.get(Dose, dose.id)} |> tap_broadcast(pet)
      else
        {:error, :already_recorded}
      end
    end
  end

  @doc """
  Marks every pending dose that is past its grace window **missed**. Called by the reminder cron;
  returns `{:ok, count}`.
  """
  def mark_missed_doses do
    threshold = DateTime.add(now(), -@missed_grace_hours, :hour)

    {count, _} =
      Repo.update_all(
        from(d in Dose, where: d.status == "pending" and d.due_at < ^threshold),
        set: [status: "missed", updated_at: now()]
      )

    {:ok, count}
  end

  # Broadcast a dose change on the pet's timeline topic so a live checklist refreshes.
  defp tap_broadcast({:ok, %Dose{} = dose} = result, %Pet{} = pet) do
    Phoenix.PubSub.broadcast(Goodmao2.PubSub, Logs.topic(pet), {:dose_updated, dose})
    result
  end

  defp tap_broadcast(result, _pet), do: result

  ## Materialization

  @doc """
  Idempotently generates the schedule's upcoming dose slots within the rolling horizon.

  Each `times_of_day` entry is a wall-clock time in the schedule's `timezone`; it is converted to
  a UTC instant (DST-safe via `Goodmao2.Timezone`). Only future slots (`due_at >= now`) inside the
  horizon are created, and the unique `(schedule_id, due_at)` index makes re-runs a no-op. Paused
  or deleted schedules generate nothing.
  """
  def materialize_doses(%Schedule{active: true, deleted_at: nil} = schedule) do
    from = now()
    to = DateTime.add(from, @horizon_hours, :hour)
    stamp = from

    rows =
      schedule
      |> slot_instants(from, to)
      |> Enum.map(fn due_at ->
        %{
          schedule_id: schedule.id,
          pet_id: schedule.pet_id,
          due_at: due_at,
          status: "pending",
          inserted_at: stamp,
          updated_at: stamp
        }
      end)

    Repo.insert_all(Dose, rows, on_conflict: :nothing)
    :ok
  end

  def materialize_doses(%Schedule{}), do: :ok

  # The UTC instants of every dose slot in [from, to], honoring interval_days / start / end and
  # computing each wall-clock time in the schedule's own zone.
  defp slot_instants(%Schedule{} = schedule, %DateTime{} = from, %DateTime{} = to) do
    tz = schedule.timezone
    from_date = from |> Goodmao2.Timezone.to_local(tz) |> DateTime.to_date()
    to_date = to |> Goodmao2.Timezone.to_local(tz) |> DateTime.to_date()

    for date <- Date.range(from_date, to_date),
        scheduled_day?(schedule, date),
        time <- schedule.times_of_day,
        {:ok, due_at} <- [local_slot_to_utc(date, time, tz)],
        DateTime.compare(due_at, from) != :lt,
        DateTime.compare(due_at, to) != :gt,
        do: due_at
  end

  # A date is a dosing day when it is on/after start, on/before end, and an interval_days multiple.
  defp scheduled_day?(%Schedule{} = s, %Date{} = date) do
    offset = Date.diff(date, s.start_date)

    offset >= 0 and
      (is_nil(s.end_date) or Date.compare(date, s.end_date) != :gt) and
      rem(offset, s.interval_days) == 0
  end

  defp local_slot_to_utc(date, time, tz) do
    Goodmao2.Timezone.local_naive_to_utc(NaiveDateTime.new!(date, time), tz)
  end

  defp drop_future_pending_doses(%Schedule{id: id}) do
    Repo.delete_all(
      from d in Dose,
        where: d.schedule_id == ^id and d.status == "pending" and d.due_at > ^now()
    )

    :ok
  end

  # Timing fields whose change invalidates the materialized future slots.
  defp timing_changed?(%Schedule{} = a, %Schedule{} = b) do
    Map.take(a, [:times_of_day, :interval_days, :start_date, :end_date, :timezone, :active]) !=
      Map.take(b, [:times_of_day, :interval_days, :start_date, :end_date, :timezone, :active])
  end

  ## Helpers

  defp authorize(pet, user, level) do
    if Pets.can?(pet, user, level), do: :ok, else: {:error, :unauthorized}
  end

  # Accept both string- and atom-keyed attrs from callers/tests.
  defp string_keys(attrs) do
    Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
