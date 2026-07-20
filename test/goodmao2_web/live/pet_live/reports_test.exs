defmodule Goodmao2Web.PetLive.ReportsTest do
  use Goodmao2Web.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Goodmao2.AccountsFixtures
  import Goodmao2.PetsFixtures

  alias Goodmao2.Reports

  setup :register_and_log_in_user

  describe "index" do
    test "owner can generate a report and see it listed", %{conn: conn, user: user} do
      pet = pet_fixture(user)
      log_entry_fixture(user, pet, %{"type" => "food", "data" => %{"amount" => "full"}})

      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}/reports")
      assert has_element?(lv, "#generate-report-form")

      today = Date.utc_today() |> Date.to_iso8601()

      lv
      |> form("#generate-report-form", report: %{"period_start" => today, "period_end" => today})
      |> render_submit()

      assert has_element?(lv, ".report-row")
    end

    test "a vet reader sees the list but no generate form", %{conn: conn, user: owner} do
      pet = pet_fixture(owner)
      vet = user_fixture()
      grant_fixture(pet, owner, vet, "vet")

      {:ok, _report} =
        Reports.generate_report(owner, pet, %{
          period_start: Date.utc_today(),
          period_end: Date.utc_today()
        })

      {:ok, lv, _html} = live(log_in_user(conn, vet), ~p"/pets/#{pet.id}/reports")
      refute has_element?(lv, "#generate-report-form")
      assert has_element?(lv, ".report-row")
    end
  end

  describe "show" do
    test "renders the frozen report and lets the owner create a share link", %{
      conn: conn,
      user: user
    } do
      pet = pet_fixture(user)
      log_entry_fixture(user, pet, %{"type" => "food", "data" => %{"amount" => "full"}})

      {:ok, report} =
        Reports.generate_report(user, pet, %{
          period_start: Date.utc_today(),
          period_end: Date.utc_today()
        })

      {:ok, lv, _html} = live(conn, ~p"/pets/#{pet.id}/reports/#{report.id}")
      assert has_element?(lv, "#report-body")

      future = DateTime.utc_now() |> DateTime.add(3600, :second)

      expires =
        future
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:second)
        |> to_string()
        |> String.replace(" ", "T")
        |> String.slice(0, 16)

      lv
      |> form("#report-share-form", share: %{"expires_at" => expires})
      |> render_submit()

      assert has_element?(lv, "#report-share-url")
      assert %{share_expires_at: %DateTime{}} = Reports.fetch_report(user, pet, report.id)
    end

    test "a missing report redirects to the index", %{conn: conn, user: user} do
      pet = pet_fixture(user)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/pets/#{pet.id}/reports/999999")

      assert to == "/pets/#{pet.id}/reports"
    end
  end
end
