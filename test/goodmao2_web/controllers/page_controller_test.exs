defmodule Goodmao2Web.PageControllerTest do
  use Goodmao2Web.ConnCase

  test "GET / shows the landing page to guests", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)
    assert response =~ "GoodMao"
    assert response =~ "shareable health timeline"
  end

  test "GET / renders the font-size controls next to the theme toggle", %{conn: conn} do
    response = conn |> get(~p"/") |> html_response(200)
    assert response =~ ~s(id="font-size-controls")
    assert response =~ ~s(id="font-size-decrease")
    assert response =~ ~s(id="font-size-increase")
    assert response =~ "phx:font-size-increase"
  end

  test "GET / redirects a signed-in user to their pets", %{conn: conn} do
    conn = conn |> log_in_user(Goodmao2.AccountsFixtures.user_fixture()) |> get(~p"/")
    assert redirected_to(conn) == ~p"/pets"
  end
end
