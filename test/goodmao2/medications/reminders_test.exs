defmodule Goodmao2.Medications.RemindersTest do
  use Goodmao2.DataCase, async: true
  use Oban.Testing, repo: Goodmao2.Repo

  import Goodmao2.AccountsFixtures
  import Goodmao2.PetsFixtures
  import Goodmao2.MedicationsFixtures

  alias Goodmao2.Medications
  alias Goodmao2.Medications.Dose
  alias Goodmao2.Medications.ReminderWorker
  alias Goodmao2.Notifications.Notification
  alias Goodmao2.Repo

  setup do
    owner = regular_user_fixture()
    pet = pet_fixture(owner)
    schedule = medication_schedule_fixture(owner, pet)
    %{owner: owner, pet: pet, schedule: schedule}
  end

  defp due_dose(schedule, pet) do
    Repo.insert!(%Dose{
      schedule_id: schedule.id,
      pet_id: pet.id,
      due_at: DateTime.utc_now() |> DateTime.add(-10, :minute) |> DateTime.truncate(:second),
      status: "pending"
    })
  end

  defp med_due_for(user),
    do:
      Repo.all(
        from n in Notification, where: n.user_id == ^user.id and n.type == "medication_due"
      )

  describe "dispatch_due_reminders/0" do
    test "notifies effective :write caretakers of a due dose, but not a viewer", ctx do
      %{owner: owner, pet: pet, schedule: schedule} = ctx
      co = regular_user_fixture()
      grant_fixture(pet, owner, co, "co_caretaker")
      viewer = regular_user_fixture()
      grant_fixture(pet, owner, viewer, "viewer")

      dose = due_dose(schedule, pet)

      assert {:ok, 1} = Medications.dispatch_due_reminders()

      assert [%Notification{}] = med_due_for(owner)
      assert [%Notification{payload: payload}] = med_due_for(co)
      assert payload["medication_name"] == "Amoxicillin"
      assert payload["dose_id"] == dose.id
      assert med_due_for(viewer) == []

      # The dose is stamped so it isn't re-nudged.
      assert Repo.get(Dose, dose.id).reminded_at != nil
    end

    test "is de-duped — a second run sends nothing", %{owner: owner, pet: pet, schedule: schedule} do
      due_dose(schedule, pet)

      assert {:ok, 1} = Medications.dispatch_due_reminders()
      assert {:ok, 0} = Medications.dispatch_due_reminders()
      assert length(med_due_for(owner)) == 1
    end

    test "ignores doses of a paused schedule", %{owner: owner, pet: pet, schedule: schedule} do
      due_dose(schedule, pet)
      {:ok, _} = Medications.set_active(owner, pet, schedule, false)

      assert {:ok, 0} = Medications.dispatch_due_reminders()
      assert med_due_for(owner) == []
    end
  end

  describe "ReminderWorker" do
    test "runs the sweep end to end", %{owner: owner, pet: pet, schedule: schedule} do
      due_dose(schedule, pet)

      assert :ok = perform_job(ReminderWorker, %{})
      assert [%Notification{}] = med_due_for(owner)
    end
  end
end
