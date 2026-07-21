defmodule Goodmao2Web.PetLive.MedicationsTest do
  use Goodmao2Web.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Goodmao2.AccountsFixtures
  import Goodmao2.PetsFixtures
  import Goodmao2.MedicationsFixtures

  alias Goodmao2.Medications

  setup :register_and_log_in_user

  test "a caretaker can create a schedule, which materializes doses", %{conn: conn, user: user} do
    pet = pet_fixture(user)
    {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}/medications")

    lv
    |> form("#schedule-form",
      schedule: %{
        medication_name: "Amoxicillin",
        dose: "50mg",
        times: "08:00, 20:00",
        interval_days: "1",
        start_date: Date.to_iso8601(Date.utc_today()),
        timezone: "Asia/Taipei"
      }
    )
    |> render_submit()

    assert has_element?(lv, ".schedule-title", "Amoxicillin")
    assert [schedule] = Medications.list_schedules(user, pet)
    assert schedule.medication_name == "Amoxicillin"
    assert Medications.upcoming_doses(user, pet) != []
  end

  test "invalid dose times are reported, not saved", %{conn: conn, user: user} do
    pet = pet_fixture(user)
    {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}/medications")

    html =
      lv
      |> form("#schedule-form",
        schedule: %{
          medication_name: "Amox",
          dose: "5mg",
          times: "not-a-time",
          start_date: Date.to_iso8601(Date.utc_today()),
          timezone: "Asia/Taipei"
        }
      )
      |> render_submit()

    assert html =~ "HH:MM"
    assert Medications.list_schedules(user, pet) == []
  end

  test "marking a dose Given records it and writes a timeline entry", %{conn: conn, user: user} do
    pet = pet_fixture(user)
    medication_schedule_fixture(user, pet)
    [dose | _] = Medications.upcoming_doses(user, pet)

    {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}/medications")
    lv |> element("#dose-give-#{dose.id}") |> render_click()

    assert Enum.any?(
             Medications.upcoming_doses(user, pet),
             &(&1.id == dose.id and &1.status == "given")
           )

    assert [entry] = Goodmao2.Logs.list_entries(user, pet)
    assert entry.type == "medication"
  end

  test "a viewer sees doses but no Give button and no schedule form", %{conn: conn, user: user} do
    owner = user_fixture()
    pet = pet_fixture(owner)
    medication_schedule_fixture(owner, pet)
    [dose | _] = Medications.upcoming_doses(owner, pet)
    grant_fixture(pet, owner, user, "viewer")

    {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}/medications")

    assert has_element?(lv, "#dose-#{dose.id}")
    refute has_element?(lv, "#dose-give-#{dose.id}")
    refute has_element?(lv, "#schedule-form")
  end

  test "an inaccessible pet is not found (IDOR-hidden)", %{conn: conn} do
    owner = user_fixture()
    pet = pet_fixture(owner)

    assert {:error, {:live_redirect, %{to: "/pets"}}} =
             live(conn, ~p"/pets/#{pet.id}/medications")
  end

  test "the pet page links to medications", %{conn: conn, user: user} do
    pet = pet_fixture(user)
    {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}")
    assert lv |> element("#pet-medications-link") |> render() =~ ~p"/pets/#{pet.id}/medications"
  end
end
