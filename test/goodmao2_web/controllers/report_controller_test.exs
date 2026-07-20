defmodule Goodmao2Web.ReportControllerTest do
  use Goodmao2Web.ConnCase, async: true

  import Goodmao2.AccountsFixtures
  import Goodmao2.PetsFixtures

  alias Goodmao2.Reports

  setup do
    owner = user_fixture()
    pet = pet_fixture(owner)
    log_entry_fixture(owner, pet, %{"type" => "food", "data" => %{"amount" => "full"}})

    {:ok, report} =
      Reports.generate_report(owner, pet, %{
        period_start: Date.utc_today(),
        period_end: Date.utc_today()
      })

    %{owner: owner, pet: pet, report: report}
  end

  test "an unauthenticated visitor can read a report via a valid token", %{
    conn: conn,
    owner: owner,
    pet: pet,
    report: report
  } do
    future = DateTime.utc_now() |> DateTime.add(3600, :second)
    {:ok, {_report, token}} = Reports.create_share_token(owner, pet, report, future)

    conn = get(conn, ~p"/reports/shared/#{token}")
    assert html_response(conn, 200) =~ "health summary"
    assert conn.assigns[:current_scope] == nil or conn.assigns.current_scope.user == nil
  end

  test "a garbage token is not found", %{conn: conn} do
    conn = get(conn, ~p"/reports/shared/not-a-real-token")
    assert response(conn, 404)
  end

  test "an expired token is not found", %{conn: conn, owner: owner, pet: pet, report: report} do
    future = DateTime.utc_now() |> DateTime.add(3600, :second)
    {:ok, {report, token}} = Reports.create_share_token(owner, pet, report, future)

    past = DateTime.utc_now() |> DateTime.add(-10, :second) |> DateTime.truncate(:second)
    report |> Ecto.Changeset.change(%{share_expires_at: past}) |> Goodmao2.Repo.update!()

    conn = get(conn, ~p"/reports/shared/#{token}")
    assert response(conn, 404)
  end
end
