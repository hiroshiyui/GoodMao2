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

    test "past-pets filter separates ended pets", %{conn: conn, user: user} do
      active = pet_fixture(user, %{"name" => "Active One"})
      ended = pet_fixture(user, %{"name" => "Memorial One"})

      {:ok, _} =
        Goodmao2.Pets.update_pet_lifecycle(user, ended, %{"lifecycle_status" => "passed_away"})

      {:ok, lv, _html} = live(conn, ~p"/pets")
      assert has_element?(lv, ".pet-card-name", active.name)
      refute has_element?(lv, ".pet-card-name", ended.name)

      {:ok, lv, _html} = live(conn, ~p"/pets?ended=true")
      assert has_element?(lv, ".pet-card-name", ended.name)
      refute has_element?(lv, ".pet-card-name", active.name)
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
