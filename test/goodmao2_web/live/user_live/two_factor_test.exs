defmodule Goodmao2Web.UserLive.TwoFactorTest do
  use Goodmao2Web.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Goodmao2.AccountsFixtures

  alias Goodmao2.Accounts

  # Establishes the pending-2FA session by performing a real password login.
  defp pending_conn(conn, user) do
    post(conn, ~p"/users/log-in", %{
      "user" => %{"email" => user.email, "password" => valid_user_password()}
    })
  end

  describe "challenge page" do
    test "requires a pending session", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/users/two-factor")
      assert path == ~p"/users/log-in"
    end

    test "shows the TOTP form for a TOTP user", %{conn: conn} do
      {user, _secret} = totp_user_fixture()
      conn = pending_conn(conn, set_password(user))

      {:ok, _lv, html} = live(conn, ~p"/users/two-factor")
      assert html =~ "Two-step verification"
      assert html =~ "totp_challenge_form"
      assert html =~ "use-recovery-code-link"
    end

    test "shows the security-key option for a WebAuthn user", %{conn: conn} do
      user = set_password(user_fixture())
      webauthn_credential_fixture(user)
      conn = pending_conn(conn, user)

      {:ok, _lv, html} = live(conn, ~p"/users/two-factor")
      assert html =~ "webauthn-challenge-button"
    end
  end

  describe "recovery page" do
    test "renders the recovery-code form", %{conn: conn} do
      {user, _secret} = totp_user_fixture()
      conn = pending_conn(conn, set_password(user))

      {:ok, _lv, html} = live(conn, ~p"/users/two-factor/recovery")
      assert html =~ "recovery_challenge_form"
    end
  end

  describe "forced setup page" do
    test "renders a QR code for an admin with no factor", %{conn: conn} do
      admin = set_password(admin_fixture())
      conn = pending_conn(conn, admin)
      assert redirected_to(conn) == ~p"/users/two-factor/setup"

      {:ok, _lv, html} = live(conn, ~p"/users/two-factor/setup")
      assert html =~ "Set up two-step verification"
      assert html =~ "totp-qr"
    end

    test "confirming a valid code shows recovery codes", %{conn: conn} do
      admin = set_password(admin_fixture())
      conn = pending_conn(conn, admin)

      {:ok, lv, html} = live(conn, ~p"/users/two-factor/setup")
      [_, secret_b32] = Regex.run(~r/id="totp-secret-text"[^>]*>([A-Z2-7]+)</, html)
      code = NimbleTOTP.verification_code(Base.decode32!(secret_b32, padding: false))

      html = lv |> form("#totp_setup_form", user: %{totp_code: code}) |> render_submit()
      assert html =~ "recovery-codes-list"
      assert Accounts.totp_enabled?(Accounts.get_user!(admin.id))
    end
  end
end
