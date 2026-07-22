defmodule Goodmao2Web.PetLive.EndOfCareTest do
  use Goodmao2Web.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Goodmao2.AccountsFixtures
  import Goodmao2.PetsFixtures

  alias Goodmao2.Pets

  setup :register_and_log_in_user

  describe "authorization" do
    test "a stranger is redirected to /pets (not-found, never forbidden)", %{conn: conn} do
      other = user_fixture()
      pet = pet_fixture(other)

      assert {:error, {:live_redirect, %{to: "/pets"}}} =
               live(conn, ~p"/pets/#{pet.id}/end-of-care")
    end

    test "a co-caretaker without :manage is redirected to /pets", %{conn: conn, user: user} do
      owner = user_fixture()
      pet = pet_fixture(owner)
      grant_fixture(pet, owner, user, "co_caretaker")

      assert {:error, {:live_redirect, %{to: "/pets"}}} =
               live(conn, ~p"/pets/#{pet.id}/end-of-care")
    end

    test "a viewer is redirected to /pets", %{conn: conn, user: user} do
      owner = user_fixture()
      pet = pet_fixture(owner)
      grant_fixture(pet, owner, user, "viewer")

      assert {:error, {:live_redirect, %{to: "/pets"}}} =
               live(conn, ~p"/pets/#{pet.id}/end-of-care")
    end
  end

  describe "the owner ending care" do
    test "renders the form for the owner", %{conn: conn, user: user} do
      pet = pet_fixture(user, %{"name" => "Sesame"})

      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}/end-of-care")

      assert has_element?(lv, "#eol-form")
      assert has_element?(lv, "#eol-submit")
    end

    test "transitions an active pet to a past status and preserves the record", %{
      conn: conn,
      user: user
    } do
      pet = pet_fixture(user, %{"name" => "Mochi"})

      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}/end-of-care")

      assert {:error, {:live_redirect, %{to: path}}} =
               lv
               |> form("#eol-form", pet: %{"lifecycle_status" => "passed_away"})
               |> render_submit()

      assert path == "/pets/#{pet.id}"

      # The record is preserved as a status transition, not deleted, and leaves the active list.
      reloaded = Goodmao2.Repo.get!(Goodmao2.Pets.Pet, pet.id)
      assert reloaded.lifecycle_status == "passed_away"
      assert refute_active(user, pet)
    end

    test "a backdated end date is interpreted in the user's timezone and stored UTC (ADR-0018)",
         %{conn: conn, user: user} do
      # The user reads/enters times in Taipei (UTC+8, no DST).
      {:ok, _} = Goodmao2.Accounts.update_user_profile(user, %{"timezone" => "Asia/Taipei"})
      pet = pet_fixture(user)

      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}/end-of-care")

      assert {:error, {:live_redirect, %{to: _}}} =
               lv
               |> form("#eol-form",
                 pet: %{"lifecycle_status" => "rehomed", "ended_at" => "2026-01-02T09:30"}
               )
               |> render_submit()

      reloaded = Goodmao2.Repo.get!(Goodmao2.Pets.Pet, pet.id)
      assert reloaded.lifecycle_status == "rehomed"
      # 09:30 in Taipei is stored as 01:30 UTC.
      assert reloaded.ended_at == ~U[2026-01-02 01:30:00Z]
    end

    test "the form pre-fills the end date in the viewer's local time", %{conn: conn, user: user} do
      {:ok, _} = Goodmao2.Accounts.update_user_profile(user, %{"timezone" => "Asia/Taipei"})
      pet = pet_fixture(user)

      {:ok, _} =
        Pets.update_pet_lifecycle(user, pet, %{
          "lifecycle_status" => "rehomed",
          "ended_at" => ~U[2026-01-02 01:30:00Z]
        })

      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}/end-of-care")

      # 01:30 UTC shows back as the local 09:30 in the datetime-local input.
      assert lv
             |> element("#eol-form input[name='pet[ended_at]']")
             |> render() =~ ~s(value="2026-01-02T09:30")
    end
  end

  defp refute_active(user, pet) do
    ids = Pets.list_pets(user) |> Enum.map(& &1.id)
    pet.id not in ids
  end
end
