defmodule Goodmao2Web.UnreadBadgesTest do
  @moduledoc "The nav unread badges render and update live across authenticated LiveViews."
  use Goodmao2Web.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Goodmao2.PetsFixtures

  alias Goodmao2.Notifications

  setup :register_and_log_in_user

  test "no badge is shown when everything is read", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/pets")
    refute has_element?(lv, "#nav-notifications-badge")
    refute has_element?(lv, "#nav-messages-badge")
  end

  test "an existing unread notification shows the bell badge on any page", %{
    conn: conn,
    user: user
  } do
    {:ok, _} = Notifications.create(user.id, "announcement", %{"title" => "Hi", "body" => "yo"})

    {:ok, lv, _html} = live(conn, ~p"/pets")
    assert has_element?(lv, "#nav-notifications-badge", "1")
  end

  test "the bell badge updates live when a notification arrives", %{conn: conn, user: user} do
    # Land on a page unrelated to notifications; the badge still updates via the on_mount hook.
    pet_fixture(user)
    {:ok, lv, _html} = live(conn, ~p"/pets")
    refute has_element?(lv, "#nav-notifications-badge")

    # A fan-out (or any create) broadcasts the fresh count to the user's topic.
    {:ok, _} = Notifications.create(user.id, "announcement", %{"title" => "New", "body" => "!"})

    assert render(lv) =~ "nav-notifications-badge"
    assert has_element?(lv, "#nav-notifications-badge", "1")
  end
end
