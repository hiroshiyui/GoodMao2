defmodule Goodmao2Web.PageControllerTest do
  use Goodmao2Web.ConnCase

  test "GET / shows the landing page to guests", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)
    assert response =~ "GoodMao"
    assert response =~ "shareable health timeline"
  end

  test "GET / redirects a signed-in user to their pets", %{conn: conn} do
    conn = conn |> log_in_user(Goodmao2.AccountsFixtures.user_fixture()) |> get(~p"/")
    assert redirected_to(conn) == ~p"/pets"
  end
end
