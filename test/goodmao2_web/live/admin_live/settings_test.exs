defmodule Goodmao2Web.AdminLive.SettingsTest do
  use Goodmao2Web.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Goodmao2.AccountsFixtures

  alias Goodmao2.Notifications.WebPush
  alias Goodmao2.Settings

  describe "access control" do
    test "redirects a non-admin home (IDOR-hidden)", %{conn: conn} do
      _admin = admin_fixture()
      conn = log_in_user(conn, user_fixture())
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/settings")
    end
  end

  describe "VAPID card" do
    setup %{conn: conn} do
      %{conn: log_in_user(conn, admin_fixture())}
    end

    test "shows 'Not configured' before any keys exist", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/settings")
      assert html =~ "Not configured"
      refute WebPush.vapid_configured?()
    end

    test "generating keys stores both settings rows and flips configured", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/settings")

      html = lv |> element("#generate-vapid-keys") |> render_click()

      assert html =~ "Configured"
      assert is_binary(Settings.get("vapid_public_key"))
      assert is_binary(Settings.get("vapid_private_key_encrypted"))
      assert WebPush.vapid_configured?()
    end

    test "saving the contact persists it", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/settings")

      lv
      |> form("#vapid-subject-form", vapid: %{subject: "mailto:admin@example.com"})
      |> render_submit()

      assert Settings.get("vapid_subject") == "mailto:admin@example.com"
    end
  end

  describe "System timezone card (ADR-0018)" do
    setup %{conn: conn} do
      # The DB row rolls back with the sandbox, but the Settings ETS cache is process-global —
      # reset just the cache entry (no DB in on_exit) so the default doesn't leak into other tests.
      on_exit(fn -> Goodmao2.Settings.Cache.put("default_timezone", nil) end)
      %{conn: log_in_user(conn, admin_fixture())}
    end

    test "renders the timezone select seeded with the current default", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/settings")
      assert html =~ ~s(id="system-timezone-select")
      assert html =~ "Asia/Taipei"
    end

    test "saving a zone persists the system default", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/settings")

      lv
      |> form("#timezone-form", tz: %{timezone: "Asia/Tokyo"})
      |> render_submit()

      assert Settings.get("default_timezone") == "Asia/Tokyo"
      assert Goodmao2.Timezone.system_default() == "Asia/Tokyo"
    end
  end

  describe "Media limits card (ADR-0005)" do
    setup %{conn: conn} do
      %{conn: log_in_user(conn, admin_fixture())}
    end

    test "seeds the fields with the current effective limits", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/settings")
      assert html =~ ~s(id="media-limits-form")
      # The config default for the image byte cap (8 MB) is pre-filled.
      assert html =~ ~s(value="8000000")
    end

    test "saving valid limits persists every field as a settings row", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/settings")

      lv
      |> form("#media-limits-form",
        media: %{
          max_image_bytes: "5000000",
          max_video_bytes: "20000000",
          min_image_width: "800",
          min_image_height: "600",
          max_image_width: "0",
          max_image_height: "0",
          min_video_width: "0",
          min_video_height: "0",
          max_video_width: "0",
          max_video_height: "0"
        }
      )
      |> render_submit()

      assert Goodmao2.Media.Limits.get(:max_image_bytes) == 5_000_000
      assert Goodmao2.Media.Limits.get(:min_image_width) == 800
      assert Settings.get("media_max_video_bytes") == "20000000"
    end

    test "a non-integer field rejects the whole form without saving", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin/settings")

      html =
        lv
        |> form("#media-limits-form",
          media: %{
            max_image_bytes: "oops",
            max_video_bytes: "20000000",
            min_image_width: "800",
            min_image_height: "600",
            max_image_width: "0",
            max_image_height: "0",
            min_video_width: "0",
            min_video_height: "0",
            max_video_width: "0",
            max_video_height: "0"
          }
        )
        |> render_submit()

      assert html =~ "whole number"
      # Nothing was persisted — not even the valid fields.
      assert Settings.get("media_max_video_bytes") == nil
    end
  end
end
