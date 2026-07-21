defmodule Goodmao2Web.AdminLive.AnnouncementsTest do
  use Goodmao2Web.ConnCase, async: true
  use Oban.Testing, repo: Goodmao2.Repo

  import Phoenix.LiveViewTest
  import Goodmao2.AccountsFixtures

  alias Goodmao2.Notifications.AnnouncementFanoutWorker

  describe "access control" do
    test "redirects a non-admin home (IDOR-hidden)", %{conn: conn} do
      _admin = admin_fixture()
      conn = log_in_user(conn, user_fixture())
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/announcements")
    end
  end

  describe "compose" do
    setup %{conn: conn} do
      %{conn: log_in_user(conn, admin_fixture())}
    end

    test "an admin can post an announcement, enqueuing the fan-out", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/announcements")

      lv
      |> form("#announcement-form",
        announcement: %{title: "Scheduled maintenance", body: "Tonight at 2am."}
      )
      |> render_submit()

      assert_enqueued(
        worker: AnnouncementFanoutWorker,
        args: %{"title" => "Scheduled maintenance"}
      )
    end

    test "an empty title or body is rejected", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/announcements")

      html =
        lv
        |> form("#announcement-form", announcement: %{title: "", body: ""})
        |> render_submit()

      assert html =~ "needs both a title and a body"
      refute_enqueued(worker: AnnouncementFanoutWorker)
    end
  end
end
