defmodule Goodmao2Web.UserLive.VetProfileTest do
  use Goodmao2Web.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Goodmao2.AccountsFixtures

  alias Goodmao2.Accounts

  setup :register_and_log_in_user

  test "submits credentials and shows a pending status", %{conn: conn, user: user} do
    {:ok, lv, _html} = live(conn, ~p"/users/vet-profile")

    lv
    |> form("#vet-profile-form",
      vet_profile: %{
        "license_number" => "VET-123",
        "licensing_body" => "State Board",
        "region" => "Taiwan",
        "clinic_name" => "Happy Clinic"
      }
    )
    |> render_submit()

    assert has_element?(lv, "#vet-profile-status", "Pending review")
    assert %{verification_status: "pending"} = Accounts.get_vet_profile(user)
  end

  test "shows validation errors for missing required fields", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/users/vet-profile")

    html =
      lv
      |> form("#vet-profile-form", vet_profile: %{"license_number" => ""})
      |> render_submit()

    assert html =~ "can&#39;t be blank"
  end

  test "a verified profile shows the verified badge", %{conn: conn, user: user} do
    verified_vet_profile_fixture(user)
    {:ok, lv, _html} = live(conn, ~p"/users/vet-profile")
    assert has_element?(lv, "#vet-profile-status", "Verified")
  end
end
