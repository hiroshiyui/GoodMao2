defmodule Goodmao2Web.AdminLiveTest do
  # async: false — the registration-gate test mutates the global `:site_owner_email`
  # app env, which would otherwise leak into concurrently-running async tests.
  use Goodmao2Web.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Goodmao2.AccountsFixtures

  describe "access control" do
    test "redirects an anonymous visitor to log in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/admin")
    end

    test "redirects a non-admin user home (IDOR-hidden)", %{conn: conn} do
      # The first registered account is the admin; occupy that slot so the next is not.
      _admin = admin_fixture()
      conn = log_in_user(conn, user_fixture())
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin")
    end

    test "lets the administrator in", %{conn: conn} do
      conn = log_in_user(conn, admin_fixture())
      {:ok, _lv, html} = live(conn, ~p"/admin")
      assert html =~ "Administration"
    end
  end

  describe "site overview" do
    setup %{conn: conn} do
      admin = admin_fixture()
      %{conn: log_in_user(conn, admin), admin: admin}
    end

    test "shows the administrator's identity and the user count", %{conn: conn, admin: admin} do
      # Another (non-admin) account so the count is not just the admin.
      _other = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/admin")

      # Fixtures have no @handle, so account_label falls back to the email.
      assert has_element?(lv, "#admin-identity", admin.email)

      # Two users exist: the admin and the other account.
      assert has_element?(lv, "#admin-user-count", "2")
    end

    test "reports an open registration gate by default", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/admin")
      assert has_element?(lv, "#admin-registration-gate", "Open")
    end

    test "reports a restricted gate when a site-owner email is configured", %{conn: conn} do
      prev = Application.get_env(:goodmao2, :site_owner_email)
      Application.put_env(:goodmao2, :site_owner_email, "owner@example.com")
      on_exit(fn -> restore_env(:site_owner_email, prev) end)

      {:ok, lv, _html} = live(conn, ~p"/admin")
      assert has_element?(lv, "#admin-registration-gate", "Restricted")
      assert has_element?(lv, "#admin-registration-gate", "owner@example.com")
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:goodmao2, key)
  defp restore_env(key, value), do: Application.put_env(:goodmao2, key, value)
end
