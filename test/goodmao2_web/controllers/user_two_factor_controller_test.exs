defmodule Goodmao2Web.UserTwoFactorControllerTest do
  use Goodmao2Web.ConnCase, async: true

  import Goodmao2.AccountsFixtures

  alias Goodmao2.Accounts

  # Drives a real password login so the pending-2FA session markers are set exactly as in
  # production. Returns the conn holding the pending session (no user_token yet).
  defp start_login(conn, user) do
    post(conn, ~p"/users/log-in", %{
      "user" => %{"email" => user.email, "password" => valid_user_password()}
    })
  end

  defp totp_login_user do
    {user, secret} = totp_user_fixture()
    {set_password(user), secret}
  end

  describe "pending state guard" do
    test "TOTP verify without a pending session redirects to login", %{conn: conn} do
      conn = post(conn, ~p"/users/two-factor/totp", %{"user" => %{"totp_code" => "123456"}})
      assert redirected_to(conn) == ~p"/users/log-in"
      refute get_session(conn, :user_token)
    end
  end

  describe "TOTP challenge" do
    test "a valid code issues the session token", %{conn: conn} do
      {user, secret} = totp_login_user()

      conn = start_login(conn, user)
      assert redirected_to(conn) == ~p"/users/two-factor"
      refute get_session(conn, :user_token)

      code = NimbleTOTP.verification_code(secret)
      conn = post(conn, ~p"/users/two-factor/totp", %{"user" => %{"totp_code" => code}})

      assert get_session(conn, :user_token)
      refute get_session(conn, :pending_2fa_user_id)
      assert redirected_to(conn) == ~p"/"
    end

    test "a wrong code is refused and issues no token", %{conn: conn} do
      {user, _secret} = totp_login_user()

      conn =
        conn
        |> start_login(user)
        |> post(~p"/users/two-factor/totp", %{"user" => %{"totp_code" => "000000"}})

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/two-factor"
      assert get_session(conn, :pending_2fa_attempts) == 1
    end

    test "five wrong codes lock the attempt out and drop the pending session", %{conn: conn} do
      {user, _secret} = totp_login_user()
      conn = start_login(conn, user)

      conn =
        Enum.reduce(1..5, conn, fn _i, conn ->
          post(conn, ~p"/users/two-factor/totp", %{"user" => %{"totp_code" => "000000"}})
        end)

      assert redirected_to(conn) == ~p"/users/log-in"
      refute get_session(conn, :user_token)
      # The whole session is dropped: the cookie is cleared (max-age 0) on the response.
      assert conn.resp_cookies["_goodmao2_key"].max_age == 0
    end
  end

  describe "recovery code" do
    test "a valid recovery code issues the session and is single-use", %{conn: conn} do
      {user, _secret} = totp_login_user()
      [code | _] = Accounts.generate_recovery_codes(user)

      conn = start_login(conn, user)
      conn = post(conn, ~p"/users/two-factor/recovery", %{"user" => %{"recovery_code" => code}})

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
      # The code is now consumed.
      assert Accounts.verify_recovery_code(Accounts.get_user!(user.id), code) == :error
    end

    test "an invalid recovery code is refused", %{conn: conn} do
      {user, _secret} = totp_login_user()

      conn =
        conn
        |> start_login(user)
        |> post(~p"/users/two-factor/recovery", %{"user" => %{"recovery_code" => "zzzz-zzzz"}})

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/two-factor/recovery"
    end
  end

  describe "forced-setup completion guard" do
    test "an admin login with no factor lands on setup, and /complete is refused until enrolled",
         %{conn: conn} do
      admin = set_password(admin_fixture())

      conn = start_login(conn, admin)
      assert redirected_to(conn) == ~p"/users/two-factor/setup"
      refute get_session(conn, :user_token)

      # Completing before any factor is enrolled must NOT issue a token.
      conn = post(conn, ~p"/users/two-factor/complete", %{})
      assert redirected_to(conn) == ~p"/users/two-factor/setup"
      refute get_session(conn, :user_token)

      # Once a factor exists, completion issues the session.
      {:ok, _} = Accounts.enable_totp(admin, Accounts.generate_totp_secret())
      conn = post(conn, ~p"/users/two-factor/complete", %{})
      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
    end
  end
end
