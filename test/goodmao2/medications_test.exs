defmodule Goodmao2.MedicationsTest do
  use Goodmao2.DataCase, async: true

  import Goodmao2.AccountsFixtures
  import Goodmao2.PetsFixtures
  import Goodmao2.MedicationsFixtures

  alias Goodmao2.Medications
  alias Goodmao2.Medications.{Schedule, Dose}
  alias Goodmao2.Logs
  alias Goodmao2.Repo

  setup do
    owner = regular_user_fixture()
    pet = pet_fixture(owner)
    %{owner: owner, pet: pet}
  end

  describe "create_schedule/3 authorization" do
    test "owner, co-caretaker, and vet (:write) can create", %{owner: owner, pet: pet} do
      assert {:ok, %Schedule{}} =
               Medications.create_schedule(owner, pet, valid_schedule_attributes())

      co = regular_user_fixture()
      grant_fixture(pet, owner, co, "co_caretaker")

      assert {:ok, %Schedule{}} =
               Medications.create_schedule(co, pet, valid_schedule_attributes())

      vet = regular_user_fixture()
      grant_fixture(pet, owner, vet, "vet")

      assert {:ok, %Schedule{}} =
               Medications.create_schedule(vet, pet, valid_schedule_attributes())
    end

    test "a viewer (read-only) and a stranger cannot create", %{owner: owner, pet: pet} do
      viewer = regular_user_fixture()
      grant_fixture(pet, owner, viewer, "viewer")

      assert {:error, :unauthorized} =
               Medications.create_schedule(viewer, pet, valid_schedule_attributes())

      stranger = regular_user_fixture()

      assert {:error, :unauthorized} =
               Medications.create_schedule(stranger, pet, valid_schedule_attributes())
    end

    test "records the author and pet", %{owner: owner, pet: pet} do
      assert {:ok, schedule} =
               Medications.create_schedule(owner, pet, valid_schedule_attributes())

      assert schedule.created_by_user_id == owner.id
      assert schedule.pet_id == pet.id
    end
  end

  describe "create_schedule/3 validation" do
    test "requires at least one dose time", %{owner: owner, pet: pet} do
      attrs = valid_schedule_attributes(%{"times_of_day" => []})
      assert {:error, changeset} = Medications.create_schedule(owner, pet, attrs)
      assert %{times_of_day: ["needs at least one dose time"]} = errors_on(changeset)
    end

    test "rejects an invalid timezone", %{owner: owner, pet: pet} do
      attrs = valid_schedule_attributes(%{"timezone" => "Bogus/Zone"})
      assert {:error, changeset} = Medications.create_schedule(owner, pet, attrs)
      assert %{timezone: ["is not a valid timezone"]} = errors_on(changeset)
    end

    test "rejects an end date before the start date", %{owner: owner, pet: pet} do
      attrs =
        valid_schedule_attributes(%{
          "start_date" => ~D[2026-07-10],
          "end_date" => ~D[2026-07-01]
        })

      assert {:error, changeset} = Medications.create_schedule(owner, pet, attrs)
      assert %{end_date: ["cannot be before the start date"]} = errors_on(changeset)
    end
  end

  describe "reads are authorization-gated (IDOR-hidden)" do
    test "list_schedules returns for a reader, [] otherwise", %{owner: owner, pet: pet} do
      medication_schedule_fixture(owner, pet)

      assert [%Schedule{}] = Medications.list_schedules(owner, pet)
      assert Medications.list_schedules(regular_user_fixture(), pet) == []
    end

    test "get_schedule is existence-hidden for a non-reader", %{owner: owner, pet: pet} do
      schedule = medication_schedule_fixture(owner, pet)

      assert %Schedule{} = Medications.get_schedule(owner, pet, schedule.id)
      assert Medications.get_schedule(regular_user_fixture(), pet, schedule.id) == nil
    end

    test "a soft-deleted schedule is excluded from reads", %{owner: owner, pet: pet} do
      schedule = medication_schedule_fixture(owner, pet)
      assert {:ok, _} = Medications.delete_schedule(owner, pet, schedule)

      assert Medications.list_schedules(owner, pet) == []
      assert Medications.get_schedule(owner, pet, schedule.id) == nil
    end
  end

  describe "update / set_active / delete authorization" do
    test "a writer can update; a viewer cannot", %{owner: owner, pet: pet} do
      schedule = medication_schedule_fixture(owner, pet)

      assert {:ok, updated} =
               Medications.update_schedule(owner, pet, schedule, %{"dose" => "100mg"})

      assert updated.dose == "100mg"

      viewer = regular_user_fixture()
      grant_fixture(pet, owner, viewer, "viewer")

      assert {:error, :unauthorized} =
               Medications.update_schedule(viewer, pet, schedule, %{"dose" => "1mg"})
    end

    test "delete requires :manage — a co-caretaker (write, not manage) cannot", %{
      owner: owner,
      pet: pet
    } do
      schedule = medication_schedule_fixture(owner, pet)
      co = regular_user_fixture()
      grant_fixture(pet, owner, co, "co_caretaker")

      assert {:error, :unauthorized} = Medications.delete_schedule(co, pet, schedule)
      assert {:ok, deleted} = Medications.delete_schedule(owner, pet, schedule)
      assert deleted.deleted_at != nil
    end

    test "set_active pauses and resumes", %{owner: owner, pet: pet} do
      schedule = medication_schedule_fixture(owner, pet)
      assert {:ok, paused} = Medications.set_active(owner, pet, schedule, false)
      refute paused.active
      assert {:ok, resumed} = Medications.set_active(owner, pet, paused, true)
      assert resumed.active
    end
  end

  describe "dose materialization" do
    test "creates future slots at the schedule's local dose times", %{owner: owner, pet: pet} do
      tz = "Asia/Taipei"
      medication_schedule_fixture(owner, pet, %{"timezone" => tz})
      doses = Medications.upcoming_doses(owner, pet)

      assert doses != []
      # Every slot lands on one of the configured wall-clock times in the schedule's zone...
      assert Enum.all?(doses, fn d -> local_time(d, tz) in [~T[08:00:00], ~T[20:00:00]] end)
      # ...and no slot is beyond the ~48h horizon.
      horizon = DateTime.add(DateTime.utc_now(), 49, :hour)
      assert Enum.all?(doses, fn d -> DateTime.compare(d.due_at, horizon) != :gt end)
    end

    test "honors interval_days (every other day)", %{owner: owner, pet: pet} do
      schedule =
        medication_schedule_fixture(owner, pet, %{
          "times_of_day" => [~T[08:00:00]],
          "interval_days" => 2
        })

      doses = Medications.upcoming_doses(owner, pet)

      # Every dosing day is an even number of days from the start — odd days are skipped.
      assert Enum.all?(doses, fn d ->
               rem(Date.diff(local_date(d, schedule.timezone), schedule.start_date), 2) == 0
             end)
    end

    test "never generates a slot past the end_date", %{owner: owner, pet: pet} do
      end_date = Date.add(Date.utc_today(), 1)
      schedule = medication_schedule_fixture(owner, pet, %{"end_date" => end_date})

      doses = Medications.upcoming_doses(owner, pet)

      assert Enum.all?(doses, fn d ->
               Date.compare(local_date(d, schedule.timezone), end_date) != :gt
             end)
    end

    test "is idempotent — re-materializing adds no duplicates", %{owner: owner, pet: pet} do
      schedule = medication_schedule_fixture(owner, pet)
      count = length(Medications.upcoming_doses(owner, pet))

      assert :ok = Medications.materialize_doses(schedule)
      assert length(Medications.upcoming_doses(owner, pet)) == count
    end

    test "a paused schedule has no upcoming doses", %{owner: owner, pet: pet} do
      schedule = medication_schedule_fixture(owner, pet)
      assert Medications.upcoming_doses(owner, pet) != []

      {:ok, _} = Medications.set_active(owner, pet, schedule, false)
      assert Medications.upcoming_doses(owner, pet) == []
    end
  end

  describe "mark_dose_given/4" do
    setup %{owner: owner, pet: pet} do
      medication_schedule_fixture(owner, pet, %{
        "medication_name" => "Amoxicillin",
        "dose" => "50mg"
      })

      [dose | _] = Medications.upcoming_doses(owner, pet)
      %{dose: dose}
    end

    test "claims the dose and writes a medication timeline entry", %{
      owner: owner,
      pet: pet,
      dose: dose
    } do
      assert {:ok, given} = Medications.mark_dose_given(owner, pet, dose)
      assert given.status == "given"
      assert given.given_at != nil
      assert given.recorded_by_user_id == owner.id
      assert given.log_entry_id != nil

      # A normal medication entry lands on the timeline (reused type, no parallel history).
      assert [entry] = Logs.list_entries(owner, pet)
      assert entry.type == "medication"
      assert entry.id == given.log_entry_id
      assert entry.data["medication_name"] == "Amoxicillin"
    end

    test "a co-caretaker can give; a viewer cannot", %{owner: owner, pet: pet, dose: dose} do
      co = regular_user_fixture()
      grant_fixture(pet, owner, co, "co_caretaker")
      assert {:ok, _} = Medications.mark_dose_given(co, pet, dose)

      # A fresh dose for the viewer attempt.
      [dose2 | _] = Enum.filter(Medications.upcoming_doses(owner, pet), &(&1.status == "pending"))
      viewer = regular_user_fixture()
      grant_fixture(pet, owner, viewer, "viewer")
      assert {:error, :unauthorized} = Medications.mark_dose_given(viewer, pet, dose2)
    end

    test "the atomic claim rejects a second recording (TOCTOU)", %{
      owner: owner,
      pet: pet,
      dose: dose
    } do
      assert {:ok, _} = Medications.mark_dose_given(owner, pet, dose)
      # The same slot, already claimed, cannot be recorded again — even from the stale struct.
      assert {:error, :already_recorded} = Medications.mark_dose_given(owner, pet, dose)
      # Exactly one timeline entry was written.
      assert length(Logs.list_entries(owner, pet)) == 1
    end

    test "a dose belonging to another pet cannot be stamped via an accessible pet", %{
      owner: owner,
      pet: pet,
      dose: dose
    } do
      # The caller owns `other_pet` too, so authorization on it passes — but `dose` belongs to
      # `pet`, not `other_pet`. The cross-pet claim must be existence-hidden (:not_found), not
      # allowed to stamp a foreign pet's dose.
      other_pet = pet_fixture(owner)

      assert {:error, :not_found} = Medications.mark_dose_given(owner, other_pet, dose)
      assert {:error, :not_found} = Medications.mark_dose_skipped(owner, other_pet, dose)

      # The dose is untouched and still claimable on its real pet.
      assert {:ok, given} = Medications.mark_dose_given(owner, pet, dose)
      assert given.status == "given"
    end
  end

  describe "mark_dose_skipped/3 and mark_missed_doses/0" do
    test "skipping claims the dose without a log entry", %{owner: owner, pet: pet} do
      medication_schedule_fixture(owner, pet)
      [dose | _] = Medications.upcoming_doses(owner, pet)

      assert {:ok, skipped} = Medications.mark_dose_skipped(owner, pet, dose)
      assert skipped.status == "skipped"
      assert Logs.list_entries(owner, pet) == []

      assert {:error, :already_recorded} = Medications.mark_dose_skipped(owner, pet, dose)
    end

    test "a pending dose past its grace window is marked missed; a recent one is not", %{
      owner: owner,
      pet: pet
    } do
      schedule = medication_schedule_fixture(owner, pet)
      overdue = insert_dose(schedule, pet, DateTime.add(now(), -3, :hour))
      recent = insert_dose(schedule, pet, DateTime.add(now(), -30, :minute))

      assert {:ok, count} = Medications.mark_missed_doses()
      assert count >= 1
      assert Repo.get(Dose, overdue.id).status == "missed"
      assert Repo.get(Dose, recent.id).status == "pending"
    end
  end

  defp insert_dose(schedule, pet, %DateTime{} = due_at) do
    Repo.insert!(%Dose{
      schedule_id: schedule.id,
      pet_id: pet.id,
      due_at: DateTime.truncate(due_at, :second),
      status: "pending"
    })
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp local_time(dose, tz), do: dose.due_at |> DateTime.shift_zone!(tz) |> DateTime.to_time()
  defp local_date(dose, tz), do: dose.due_at |> DateTime.shift_zone!(tz) |> DateTime.to_date()
end
