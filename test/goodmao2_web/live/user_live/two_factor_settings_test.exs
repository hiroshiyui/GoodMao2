defmodule Goodmao2Web.UserLive.TwoFactorSettingsTest do
  use Goodmao2Web.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Goodmao2.AccountsFixtures

  alias Goodmao2.Accounts

  # Logs in a non-admin user with fresh sudo mode (so the last-factor guard, which only
  # applies to admins, doesn't interfere).
  defp log_in_regular(conn) do
    admin_fixture()
    user = user_fixture()
    {log_in_user(conn, user), user}
  end

  defp extract_secret(html) do
    [_, secret] = Regex.run(~r/id="totp-settings-secret"[^>]*>([A-Z2-7]+)</, html)
    secret
  end

  describe "sudo mode" do
    test "redirects when the user is not in sudo mode", %{conn: conn} do
      admin_fixture()
      user = user_fixture()
      stale = DateTime.add(DateTime.utc_now(:second), -11, :minute)
      conn = log_in_user(conn, user, token_authenticated_at: stale)

      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/users/settings/two-factor")
      assert path == ~p"/users/log-in"
    end
  end

  describe "sudo mode lapsing while the page is open" do
    setup %{conn: conn} do
      {conn, user} = log_in_regular(conn)
      {:ok, _} = Accounts.enable_totp(user, Accounts.generate_totp_secret())
      {:ok, lv, _html} = live(conn, ~p"/users/settings/two-factor")

      # Time can't pass inside a test, so age the mounted session's authentication instead —
      # exactly what a tab left open past its sudo window holds.
      stale = DateTime.add(DateTime.utc_now(:second), -30, :minute)

      :sys.replace_state(lv.pid, fn %{socket: socket} = state ->
        scope = socket.assigns.current_scope
        user = %{scope.user | authenticated_at: stale}
        %{state | socket: Phoenix.Component.assign(socket, :current_scope, %{scope | user: user})}
      end)

      %{lv: lv, user: user}
    end

    # The event crashes the LiveView (the `UserLive.Settings` convention); its remount then
    # meets `:require_sudo_mode` and is sent to re-authenticate.
    @tag :capture_log
    test "turning the authenticator off is refused", %{lv: lv, user: user} do
      Process.flag(:trap_exit, true)
      catch_exit(render_click(lv, "disable_totp", %{}))

      assert Accounts.totp_enabled?(Accounts.get_user!(user.id))
    end

    @tag :capture_log
    test "regenerating recovery codes is refused", %{lv: lv, user: user} do
      before = Accounts.recovery_codes_remaining(user)
      Process.flag(:trap_exit, true)
      catch_exit(render_click(lv, "regenerate_recovery_codes", %{}))

      assert Accounts.recovery_codes_remaining(user) == before
    end
  end

  describe "TOTP enrollment" do
    test "enables TOTP with a valid code and reveals recovery codes", %{conn: conn} do
      {conn, _user} = log_in_regular(conn)
      {:ok, lv, _html} = live(conn, ~p"/users/settings/two-factor")

      html = lv |> element("#totp-begin") |> render_click()
      secret = Base.decode32!(extract_secret(html), padding: false)
      code = NimbleTOTP.verification_code(secret)

      html = lv |> form("#totp_enable_form", user: %{totp_code: code}) |> render_submit()

      assert html =~ "Authenticator app turned on"
      assert has_element?(lv, "#recovery-codes-display")
      assert has_element?(lv, "#totp-status-on")
    end

    test "rejects a wrong code", %{conn: conn} do
      {conn, _user} = log_in_regular(conn)
      {:ok, lv, _html} = live(conn, ~p"/users/settings/two-factor")

      lv |> element("#totp-begin") |> render_click()
      html = lv |> form("#totp_enable_form", user: %{totp_code: "000000"}) |> render_submit()

      assert html =~ "not valid"
      refute has_element?(lv, "#totp-status-on")
    end
  end

  describe "disabling and recovery codes" do
    setup %{conn: conn} do
      {conn, user} = log_in_regular(conn)
      {:ok, _} = Accounts.enable_totp(user, Accounts.generate_totp_secret())
      %{conn: conn, user: user}
    end

    test "disables TOTP", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings/two-factor")
      html = lv |> element("#totp-disable") |> render_click()

      assert html =~ "Authenticator app turned off"
      assert has_element?(lv, "#totp-status-off")
    end

    test "regenerates recovery codes", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings/two-factor")
      html = lv |> element("#regenerate-recovery-codes") |> render_click()

      assert html =~ "New recovery codes generated"
      assert has_element?(lv, "#recovery-codes-display")
    end
  end

  describe "security keys" do
    test "lists and removes a key", %{conn: conn} do
      {conn, user} = log_in_regular(conn)
      cred = webauthn_credential_fixture(user, %{label: "My Key"})
      {:ok, lv, html} = live(conn, ~p"/users/settings/two-factor")

      assert html =~ "My Key"
      html = lv |> element("#security-key-delete-#{cred.id}") |> render_click()

      assert html =~ "Security key removed"
      refute has_element?(lv, "#security-key-#{cred.id}")
    end
  end

  describe "admin last-factor guard" do
    test "an admin cannot remove their only factor", %{conn: conn} do
      admin = admin_fixture()
      {:ok, _} = Accounts.enable_totp(admin, Accounts.generate_totp_secret())
      conn = log_in_user(conn, admin)

      {:ok, lv, _html} = live(conn, ~p"/users/settings/two-factor")
      html = lv |> element("#totp-disable") |> render_click()

      assert html =~ "keep at least one second factor"
      assert has_element?(lv, "#totp-status-on")
    end
  end
end
