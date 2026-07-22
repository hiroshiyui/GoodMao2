defmodule Goodmao2Web.NotificationLiveTest do
  use Goodmao2Web.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Goodmao2.Notifications

  setup :register_and_log_in_user

  test "shows the empty state with no notifications", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/notifications")
    assert has_element?(lv, "#notifications-empty")
  end

  test "lists a notification and renders its rendered copy", %{conn: conn, user: user} do
    {:ok, _} =
      Notifications.create(user.id, "announcement", %{"title" => "Downtime", "body" => "Tonight"})

    {:ok, lv, _html} = live(conn, ~p"/notifications")
    assert has_element?(lv, ".notification-title", "Downtime")
    assert has_element?(lv, ".notification-summary", "Tonight")
  end

  test "marking one read clears its unread marker", %{conn: conn, user: user} do
    {:ok, n} =
      Notifications.create(user.id, "announcement", %{"title" => "Hi", "body" => "There"})

    {:ok, lv, _html} = live(conn, ~p"/notifications")
    assert has_element?(lv, "#mark-read-#{n.id}")

    lv |> element("#mark-read-#{n.id}") |> render_click()

    refute has_element?(lv, "#mark-read-#{n.id}")
    assert Notifications.unread_count(user) == 0
  end

  test "mark all read zeroes the unread count", %{conn: conn, user: user} do
    {:ok, _} = Notifications.create(user.id, "announcement", %{"title" => "a", "body" => "1"})
    {:ok, _} = Notifications.create(user.id, "announcement", %{"title" => "b", "body" => "2"})

    {:ok, lv, _html} = live(conn, ~p"/notifications")
    lv |> element("#mark-all-read") |> render_click()

    assert Notifications.unread_count(user) == 0
  end

  test "dismissing removes the row", %{conn: conn, user: user} do
    {:ok, n} = Notifications.create(user.id, "announcement", %{"title" => "x", "body" => "y"})

    {:ok, lv, _html} = live(conn, ~p"/notifications")
    lv |> element("#dismiss-#{n.id}") |> render_click()

    refute has_element?(lv, "#notification-#{n.id}")
  end

  test "a new notification streams into the open feed without a reload", %{
    conn: conn,
    user: user
  } do
    # The UnreadBadges on_mount hook subscribes the process and attaches a :handle_info hook that
    # runs BEFORE this LiveView's own handle_info. That hook must PASS {:notifications_changed, _}
    # through (:cont), not halt it, or this feed never re-streams. Drive the message through the
    # hook chain deterministically (a raw send is FIFO before the next render).
    {:ok, lv, _html} = live(conn, ~p"/notifications")
    assert has_element?(lv, "#notifications-empty")

    {:ok, n} =
      Notifications.create(user.id, "announcement", %{"title" => "Fresh", "body" => "Live"})

    send(lv.pid, {:notifications_changed, %{unread: 1}})
    render(lv)

    assert has_element?(lv, "#notifications-#{n.id}")
    assert has_element?(lv, ".notification-title", "Fresh")
  end
end
