defmodule Goodmao2Web.PetLiveTest do
  use Goodmao2Web.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Goodmao2.AccountsFixtures
  import Goodmao2.PetsFixtures

  setup :register_and_log_in_user

  describe "Index" do
    test "shows the empty state then a created pet", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/pets")
      refute has_element?(lv, ".pet-card-name")

      pet_fixture(user, %{"name" => "Sesame"})

      {:ok, lv, _html} = live(conn, ~p"/pets")
      assert has_element?(lv, ".pet-card-name", "Sesame")
    end

    test "the active list keeps past pets on their own quiet surface", %{conn: conn, user: user} do
      active = pet_fixture(user, %{"name" => "Active One"})
      ended = pet_fixture(user, %{"name" => "Memorial One"})

      {:ok, _} =
        Goodmao2.Pets.update_pet_lifecycle(user, ended, %{"lifecycle_status" => "passed_away"})

      {:ok, lv, _html} = live(conn, ~p"/pets")
      assert has_element?(lv, ".pet-card-name", active.name)
      refute has_element?(lv, ".pet-card-name", ended.name)
      # Past pets are not surfaced beside the living — no filter tab on the active list.
      refute has_element?(lv, "#pets-filter")

      {:ok, past_lv, _html} = live(conn, ~p"/pets/past")
      assert has_element?(past_lv, ".pet-card-name", ended.name)
      refute has_element?(past_lv, ".pet-card-name", active.name)
      assert has_element?(past_lv, "#past-pets-back")
    end

    test "the past-pets surface is reached by a subtle link from settings", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")
      assert lv |> element("#past-pets-link a") |> render() =~ ~p"/pets/past"
    end
  end

  describe "Form" do
    test "creates a pet and redirects to its page", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/pets/new")

      assert {:ok, _show, html} =
               lv
               |> form("#pet-form",
                 pet: %{name: "Biscuit", species: "cat", sex: "male", weight_unit: "grams"}
               )
               |> render_submit()
               |> follow_redirect(conn)

      assert html =~ "Biscuit"
    end
  end

  describe "Show + QuickLog" do
    test "logs an entry that appears on the timeline", %{conn: conn, user: user} do
      pet = pet_fixture(user)
      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}")

      refute has_element?(lv, ".timeline-entry-type")

      lv
      |> form("#quicklog-form", log: %{amount: "full", food_type: "Tuna"})
      |> render_submit()

      assert has_element?(lv, ".timeline-entry-type", "Food")
    end

    test "a submitted occurred_at is interpreted in the user's timezone (ADR-0018)", %{
      conn: conn,
      user: user
    } do
      # The user reads/enters times in Taipei (UTC+8, no DST).
      {:ok, _} = Goodmao2.Accounts.update_user_profile(user, %{"timezone" => "Asia/Taipei"})
      pet = pet_fixture(user)
      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}")

      lv
      |> form("#quicklog-form",
        log: %{amount: "full", food_type: "Tuna", occurred_at: "2026-07-21T08:30"}
      )
      |> render_submit()

      # 08:30 in Taipei is stored as 00:30 UTC...
      [entry] = Goodmao2.Logs.list_entries(user, pet)
      assert entry.occurred_at == ~U[2026-07-21 00:30:00Z]

      # ...and renders back as the local 08:30 for this viewer.
      assert has_element?(lv, ".timeline-entry-time", "2026-07-21 08:30")
    end

    test "a one-tap button logs a common value immediately", %{conn: conn, user: user} do
      pet = pet_fixture(user)
      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}")

      # Food is the default type; one tap on "Refused" logs it with no further input.
      assert has_element?(lv, "#quicktap-food-refused")
      lv |> element("#quicktap-food-refused") |> render_click()

      assert has_element?(lv, ".timeline-entry-type", "Food")
      assert has_element?(lv, ".timeline-entry-summary", "Refused food")
    end

    test "a type needing input shows the manual form with no one-tap buttons", %{
      conn: conn,
      user: user
    } do
      pet = pet_fixture(user)
      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}")

      lv |> element("#quicklog-type-weight") |> render_click()

      refute has_element?(lv, "#quicktap-buttons")
      assert has_element?(lv, "#quicklog-form")
    end

    test "logs a text-only daily-life note", %{conn: conn, user: user} do
      pet = pet_fixture(user)
      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}")

      lv |> element("#quicklog-type-life") |> render_click()

      lv
      |> form("#quicklog-form", log: %{note: "Chased the laser pointer for ten minutes."})
      |> render_submit()

      assert has_element?(lv, ".timeline-entry-type", "Daily life")
      assert has_element?(lv, ".timeline-entry-note", "Chased the laser pointer")
    end

    test "a daily-life note requires a caption", %{conn: conn, user: user} do
      pet = pet_fixture(user)
      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}")

      lv |> element("#quicklog-type-life") |> render_click()

      html =
        lv
        |> form("#quicklog-form", log: %{note: ""})
        |> render_submit()

      assert html =~ "note can&#39;t be blank"
      refute has_element?(lv, ".timeline-entry-type")
    end

    test "a viewer sees the timeline but no QuickLog", %{conn: conn, user: user} do
      owner = user_fixture()
      pet = pet_fixture(owner)
      log_entry_fixture(owner, pet, %{"type" => "food", "data" => %{"amount" => "full"}})
      grant_fixture(pet, owner, user, "viewer")

      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}")
      assert has_element?(lv, ".timeline-entry-type", "Food")
      refute has_element?(lv, "#quicklog-section")
    end

    test "a vet is offered the vet-note chip and can leave a note", %{conn: conn, user: user} do
      owner = user_fixture()
      pet = pet_fixture(owner)
      grant_fixture(pet, owner, user, "vet")

      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}")

      # The vet-only chip is offered alongside the shared caretaker types.
      assert has_element?(lv, "#quicklog-type-vet_note")
      lv |> element("#quicklog-type-vet_note") |> render_click()

      lv
      |> form("#quicklog-form",
        log: %{assessment: "Possible early cystitis.", recommendation: "Recheck in 3 days."}
      )
      |> render_submit()

      assert has_element?(lv, ".timeline-entry-type", "Vet note")
    end

    test "a co-caretaker is not offered the vet-note chip", %{conn: conn, user: user} do
      owner = user_fixture()
      pet = pet_fixture(owner)
      grant_fixture(pet, owner, user, "co_caretaker")

      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}")

      # QuickLog is available (co-caretakers can write) but without the vet-only chip.
      assert has_element?(lv, "#quicklog-type-food")
      refute has_element?(lv, "#quicklog-type-vet_note")

      # A crafted event can't drop the form into the vet-only state either.
      lv |> render_hook("select_type", %{"type" => "vet_note"})
      refute has_element?(lv, "#quicklog-form textarea[name='log[assessment]']")
    end

    test "the owner is not offered the vet-note chip", %{conn: conn, user: user} do
      pet = pet_fixture(user)
      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}")
      refute has_element?(lv, "#quicklog-type-vet_note")
    end

    test "a private entry is hidden from a viewer on the timeline", %{conn: conn, user: user} do
      owner = user_fixture()
      pet = pet_fixture(owner)

      {:ok, _private} =
        Goodmao2.Logs.create_entry(owner, pet, %{
          "type" => "food",
          "data" => %{"amount" => "full"},
          "visibility" => "private"
        })

      grant_fixture(pet, owner, user, "viewer")

      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}")
      refute has_element?(lv, ".timeline-entry-type")
    end

    test "an urgent entry carries a clinical-flag chip on the timeline", %{conn: conn, user: user} do
      pet = pet_fixture(user)

      log_entry_fixture(user, pet, %{
        "type" => "bathroom",
        "data" => %{"kind" => "urine", "straining" => true}
      })

      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}")

      # The chip carries the concern in text, not colour alone.
      assert has_element?(lv, ".timeline-entry .clinical-flag", "Straining")
    end

    test "a benign entry carries no clinical-flag chip", %{conn: conn, user: user} do
      pet = pet_fixture(user)
      log_entry_fixture(user, pet, %{"type" => "food", "data" => %{"amount" => "full"}})

      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}")

      assert has_element?(lv, ".timeline-entry-type", "Food")
      refute has_element?(lv, ".timeline-entry .clinical-flag")
    end

    test "weight is entered and displayed in the pet's unit, stored as grams (roadmap §8)", %{
      conn: conn,
      user: user
    } do
      pet = pet_fixture(user, %{"weight_unit" => "pounds"})
      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}")

      lv |> element("#quicklog-type-weight") |> render_click()
      # The field is labelled in the pet's unit...
      assert has_element?(lv, "#quicklog-form label", "Weight (pounds)")

      lv |> form("#quicklog-form", log: %{weight: "10"}) |> render_submit()

      # ...stored canonically as grams (10 lb ≈ 4536 g)...
      [entry] = Goodmao2.Logs.list_entries(user, pet)
      assert entry.data["weight_grams"] == 4536
      # ...and rendered back in pounds.
      assert has_element?(lv, ".timeline-entry-summary", "10.00 lb")
    end

    test "the weight-trend chart appears once there are two or more measurements", %{
      conn: conn,
      user: user
    } do
      pet = pet_fixture(user, %{"weight_unit" => "kilograms"})
      earlier = DateTime.utc_now() |> DateTime.add(-2, :day) |> DateTime.truncate(:second)

      log_entry_fixture(user, pet, %{
        "type" => "weight",
        "data" => %{"weight_grams" => 4200},
        "occurred_at" => earlier
      })

      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}")
      # One measurement is not yet a trend.
      refute has_element?(lv, "#weight-trend")

      log_entry_fixture(user, pet, %{"type" => "weight", "data" => %{"weight_grams" => 4350}})

      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}")
      assert has_element?(lv, "#weight-trend")
      assert has_element?(lv, "#weight-latest", "4.35 kg")
      # The gain is stated in text (with a sign), not colour alone.
      assert has_element?(lv, "#weight-change", "+0.15 kg")
    end

    test "hidden history shows a notice instead of the timeline and QuickLog", %{
      conn: conn,
      user: user
    } do
      pet = pet_fixture(user)
      log_entry_fixture(user, pet, %{"type" => "food", "data" => %{"amount" => "full"}})
      {:ok, _} = Goodmao2.Pets.update_pet(user, pet, %{"history_hidden" => true})

      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}")
      assert has_element?(lv, "#history-hidden-notice")
      refute has_element?(lv, "#quicklog-section")
      refute has_element?(lv, "#timeline-section")
    end
  end

  describe "Show timeline calendar view" do
    test "toggles between the list and the calendar", %{conn: conn, user: user} do
      pet = pet_fixture(user)
      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}")

      # List is the default.
      assert has_element?(lv, "#timeline")
      refute has_element?(lv, "#timeline-calendar")

      lv |> element("#view-calendar") |> render_click()
      assert has_element?(lv, "#timeline-calendar")
      refute has_element?(lv, "#timeline")

      lv |> element("#view-list") |> render_click()
      assert has_element?(lv, "#timeline")
      refute has_element?(lv, "#timeline-calendar")
    end

    test "a day with entries is selectable and drills into that day", %{conn: conn, user: user} do
      pet = pet_fixture(user)
      log_entry_fixture(user, pet, %{"type" => "food", "data" => %{"amount" => "full"}})
      today = Date.utc_today() |> Date.to_iso8601()

      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}")
      lv |> element("#view-calendar") |> render_click()

      assert has_element?(lv, "#cal-day-#{today}")
      refute has_element?(lv, "#cal-day-detail")

      lv |> element("#cal-day-#{today}") |> render_click()
      assert has_element?(lv, "#cal-day-detail")
      assert has_element?(lv, "#cal-day-detail .timeline-entry-type", "Food")

      lv |> element("#cal-day-clear") |> render_click()
      refute has_element?(lv, "#cal-day-detail")
    end

    test "a day cell buckets an entry by the viewer's local day (ADR-0018)", %{
      conn: conn,
      user: user
    } do
      # Kiritimati is UTC+14, so a 20:00 UTC instant is 10:00 the *next* local day.
      {:ok, _} =
        Goodmao2.Accounts.update_user_profile(user, %{"timezone" => "Pacific/Kiritimati"})

      pet = pet_fixture(user)

      # A guaranteed-past instant at 20:00 UTC on the previous UTC day.
      occurred = DateTime.new!(Date.add(Date.utc_today(), -1), ~T[20:00:00], "Etc/UTC")

      log_entry_fixture(user, pet, %{
        "type" => "food",
        "data" => %{"amount" => "full"},
        "occurred_at" => occurred
      })

      utc_day = DateTime.to_date(occurred)
      local_day = occurred |> DateTime.shift_zone!("Pacific/Kiritimati") |> DateTime.to_date()
      assert local_day == Date.add(utc_day, 1)

      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}")
      lv |> element("#view-calendar") |> render_click()

      # The entry sits under its LOCAL day (a different date than the UTC day): only a cell with
      # entries gets a `cal-day-*` id/button, so the UTC-day cell has none while the local-day
      # cell drills into the entry.
      refute has_element?(lv, "#cal-day-#{Date.to_iso8601(utc_day)}")
      lv |> element("#cal-day-#{Date.to_iso8601(local_day)}") |> render_click()
      assert has_element?(lv, "#cal-day-detail .timeline-entry-type", "Food")
    end

    test "an urgent clinical day is flagged in its cell", %{conn: conn, user: user} do
      pet = pet_fixture(user)

      log_entry_fixture(user, pet, %{
        "type" => "bathroom",
        "data" => %{"kind" => "urine", "straining" => true}
      })

      today = Date.utc_today() |> Date.to_iso8601()

      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}")
      lv |> element("#view-calendar") |> render_click()

      # The urgency rides in the accessible name, not colour alone.
      assert has_element?(lv, "#cal-day-#{today}[aria-label*='urgent']")
    end

    test "month navigation moves off the current month", %{conn: conn, user: user} do
      pet = pet_fixture(user)
      log_entry_fixture(user, pet, %{"type" => "food", "data" => %{"amount" => "full"}})
      today = Date.utc_today() |> Date.to_iso8601()

      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}")
      lv |> element("#view-calendar") |> render_click()
      assert has_element?(lv, "#cal-day-#{today}")

      # The previous month's grid doesn't contain today, so the day cell disappears.
      lv |> element("#cal-prev") |> render_click()
      refute has_element?(lv, "#cal-day-#{today}")
    end
  end

  describe "Log entry page — edit + history (ADR-0009)" do
    test "the timeline links each entry to its detail page", %{conn: conn, user: user} do
      pet = pet_fixture(user)
      entry = log_entry_fixture(user, pet, %{"type" => "food", "data" => %{"amount" => "full"}})

      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}")
      assert has_element?(lv, "#entry-detail-#{entry.id}")
    end

    test "editing an entry records a revision shown in the history", %{conn: conn, user: user} do
      pet = pet_fixture(user)

      entry =
        log_entry_fixture(user, pet, %{
          "type" => "food",
          "data" => %{"amount" => "full"},
          "note" => "before"
        })

      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}/logs/#{entry.id}")
      assert has_element?(lv, "#log-edit-form")
      assert has_element?(lv, "#log-history-empty")

      lv |> form("#log-edit-form", log: %{amount: "full", note: "after"}) |> render_submit()

      assert has_element?(lv, "#log-edit-count", "1")
      assert has_element?(lv, ".log-revision-note", "before")
    end

    test "an edited entry is marked on the timeline", %{conn: conn, user: user} do
      pet = pet_fixture(user)
      entry = log_entry_fixture(user, pet, %{"type" => "food", "data" => %{"amount" => "full"}})
      {:ok, _} = Goodmao2.Logs.update_entry(user, pet, entry, %{"note" => "changed"})

      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}")
      assert has_element?(lv, ".timeline-entry-edited", "edited")
    end

    test "a viewer sees the history but no edit form", %{conn: conn, user: user} do
      owner = user_fixture()
      pet = pet_fixture(owner)
      entry = log_entry_fixture(owner, pet, %{"type" => "food", "data" => %{"amount" => "full"}})
      {:ok, _} = Goodmao2.Logs.update_entry(owner, pet, entry, %{"note" => "changed"})
      grant_fixture(pet, owner, user, "viewer")

      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}/logs/#{entry.id}")
      assert has_element?(lv, "#log-history")
      refute has_element?(lv, "#log-edit-form")
    end

    test "at the nine-edit cap the form is replaced by a notice", %{conn: conn, user: user} do
      pet = pet_fixture(user)
      entry = log_entry_fixture(user, pet, %{"type" => "food", "data" => %{"amount" => "full"}})

      entry =
        Enum.reduce(1..Goodmao2.Logs.max_edits(), entry, fn i, acc ->
          {:ok, next} = Goodmao2.Logs.update_entry(user, pet, acc, %{"note" => "edit #{i}"})
          next
        end)

      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}/logs/#{entry.id}")
      refute has_element?(lv, "#log-edit-form")
      assert has_element?(lv, "#log-edit-limit-notice")
    end

    test "another user's entry is reported as not found", %{conn: conn} do
      other = user_fixture()
      pet = pet_fixture(other)
      entry = log_entry_fixture(other, pet, %{"type" => "food", "data" => %{"amount" => "full"}})

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/pets/#{pet.id}/logs/#{entry.id}")

      assert to == "/pets/#{pet.id}"
    end
  end

  describe "LifeLog media (ADR-0005)" do
    test "uploads a purified photo with a daily-life note", %{conn: conn, user: user} do
      pet = pet_fixture(user)

      src = Path.join(System.tmp_dir!(), "gm_up_#{System.unique_integer([:positive])}.png")

      {_, 0} =
        System.cmd(
          "ffmpeg",
          ~w(-hide_banner -v error -f lavfi -i color=c=green:s=16x16 -frames:v 1 -y) ++ [src]
        )

      content = File.read!(src)
      File.rm(src)

      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}")
      lv |> element("#quicklog-type-life") |> render_click()

      photo =
        file_input(lv, "#quicklog-form", :media, [
          %{name: "cat.png", content: content, type: "image/png"}
        ])

      render_upload(photo, "cat.png")

      lv |> form("#quicklog-form", log: %{note: "Nap in the sun"}) |> render_submit()

      assert has_element?(lv, ".timeline-entry-type", "Daily life")
      assert has_element?(lv, ".timeline-media img")
    end
  end

  describe "authorization" do
    test "accessing another user's pet is reported as not found", %{conn: conn} do
      other = user_fixture()
      pet = pet_fixture(other)

      assert {:error, {:live_redirect, %{to: "/pets"}}} = live(conn, ~p"/pets/#{pet.id}")
    end

    test "a viewer cannot open the sharing page", %{conn: conn, user: user} do
      owner = user_fixture()
      pet = pet_fixture(owner)
      grant_fixture(pet, owner, user, "viewer")

      assert {:error, {:live_redirect, %{to: "/pets"}}} = live(conn, ~p"/pets/#{pet.id}/access")
    end
  end
end
