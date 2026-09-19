defmodule Goodmao2Web.PageControllerTest do
  use Goodmao2Web.ConnCase

  test "GET / shows the landing page to guests", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)
    assert response =~ "GoodMao"
    assert response =~ "shareable health timeline"
  end

  test "GET / carries its own page title", %{conn: conn} do
    response = conn |> get(~p"/") |> html_response(200)

    # The root layout appends " · GoodMao" unconditionally, so a missing title renders a
    # bare separator -- the first thing a search engine indexes and a screen reader reads.
    assert response =~ "Health timeline for the pets you love"
    refute response =~ ~r|<title[^>]*>\s*·|
  end

  test "GET / ships the reconnect banners hidden and unwired", %{conn: conn} do
    response = conn |> get(~p"/") |> html_response(200)

    assert response =~ ~s(id="client-error")
    assert response =~ ~s(id="server-error")

    # Revealing these the instant the socket drops flashed a red error every time a phone
    # woke from sleep. assets/js/reconnect_flash.js now reveals them after a grace period,
    # so the server-rendered markup must NOT re-add the immediate wiring.
    refute response =~ "phx-disconnected"
    refute response =~ "phx-connected"
  end

  test "GET / renders the font-size controls next to the theme toggle", %{conn: conn} do
    response = conn |> get(~p"/") |> html_response(200)
    assert response =~ ~s(id="font-size-controls")
    assert response =~ ~s(id="font-size-decrease")
    assert response =~ ~s(id="font-size-increase")
    assert response =~ "phx:font-size-increase"
  end

  test "GET / gives the theme toggle a selected state and unique ids per copy", %{conn: conn} do
    response = conn |> get(~p"/") |> html_response(200)

    # Which theme is active is drawn by a CSS-positioned pill, which says nothing to a screen
    # reader. aria-pressed is the only thing that does; the inline script in root.html.heex
    # flips the chosen one to "true" and re-runs after a patch, so "false" is the correct
    # server-rendered value here.
    assert response =~ ~s(aria-pressed="false")
    assert response =~ ~s(data-phx-theme="system")
    assert response =~ ~s(data-phx-theme="light")
    assert response =~ ~s(data-phx-theme="dark")

    # The control renders twice (desktop bar + mobile menu), so its ids must not collide.
    assert response =~ ~s(id="theme-toggle")
    assert response =~ ~s(id="m-theme-toggle")
    assert response =~ ~s(id="theme-dark")
    assert response =~ ~s(id="m-theme-dark")
  end

  test "GET / redirects a signed-in user to their pets", %{conn: conn} do
    conn = conn |> log_in_user(Goodmao2.AccountsFixtures.user_fixture()) |> get(~p"/")
    assert redirected_to(conn) == ~p"/pets"
  end
end
