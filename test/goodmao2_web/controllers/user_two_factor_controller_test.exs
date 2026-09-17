defmodule Goodmao2Web.UserTwoFactorControllerTest do
  use Goodmao2Web.ConnCase, async: true

  import Goodmao2.AccountsFixtures
  import Phoenix.LiveViewTest

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
    # Lockouts log a security warning by design.
    @describetag :capture_log

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

  describe "session cookie" do
    # The pending-2FA state (and, for a forced enrollment, the raw TOTP seed) lives in the
    # session cookie, so it must be unreadable to whoever holds the cookie — not merely
    # tamper-proof.
    test "is encrypted, so the pending state can't be read out of it", %{conn: conn} do
      {user, _secret} = totp_login_user()
      conn = start_login(conn, user)
      assert get_session(conn, :pending_2fa_user_id) == user.id

      cookie = conn.resp_cookies["_goodmao2_key"].value

      decoded =
        cookie
        |> String.split(".")
        |> Enum.flat_map(fn part ->
          case Base.url_decode64(part, padding: false) do
            {:ok, bin} -> [bin]
            :error -> []
          end
        end)

      refute Enum.any?(decoded, &String.contains?(&1, "pending_2fa_user_id"))
    end
  end

  describe "server-side attempt budget" do
    # Lockouts log a security warning by design.
    @describetag :capture_log

    # Matches config :goodmao2, Goodmao2.Accounts, :login_attempts_per_hour.
    @attempts_per_hour 10

    # The per-session counter rides the signed session *cookie*: posting every guess with the
    # cookie from before the first failure means the count never rises and the session is never
    # dropped. Without a server-side budget that is an unbounded online TOTP brute force for
    # anyone holding the password.
    test "replaying the pre-failure session cookie cannot reset the attempt budget", %{
      conn: conn
    } do
      {user, secret} = totp_login_user()
      pending = start_login(conn, user)

      for _ <- 1..@attempts_per_hour do
        # Every request recycles `pending` — the same pre-failure cookie each time.
        replayed =
          post(pending, ~p"/users/two-factor/totp", %{
            "user" => %{"totp_code" => wrong_code(secret)}
          })

        assert redirected_to(replayed) == ~p"/users/two-factor"
        refute get_session(replayed, :user_token)
      end

      # The budget is spent: even the correct code is not evaluated.
      conn =
        post(pending, ~p"/users/two-factor/totp", %{
          "user" => %{"totp_code" => NimbleTOTP.verification_code(secret)}
        })

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "the budget is per user, so a fresh login does not refill it", %{conn: conn} do
      {user, secret} = totp_login_user()

      for _ <- 1..@attempts_per_hour do
        conn
        |> start_login(user)
        |> post(~p"/users/two-factor/totp", %{"user" => %{"totp_code" => wrong_code(secret)}})
      end

      conn =
        conn
        |> start_login(user)
        |> post(~p"/users/two-factor/totp", %{
          "user" => %{"totp_code" => NimbleTOTP.verification_code(secret)}
        })

      refute get_session(conn, :user_token)
    end
  end

  # Any six digits other than the current code (which a fixed "000000" would be one time in 10^6).
  defp wrong_code(secret) do
    if NimbleTOTP.verification_code(secret) == "000000", do: "000001", else: "000000"
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
    test "a challenge user cannot skip their factor by posting to /complete", %{conn: conn} do
      # An attacker who has only the password reaches the pending state legitimately, then
      # posts straight to the forced-enrollment tail. /complete must never stand in for a
      # factor: it belongs to the setup flow, and this user was never sent there.
      {user, _secret} = totp_login_user()

      conn = start_login(conn, user)
      assert redirected_to(conn) == ~p"/users/two-factor"
      refute get_session(conn, :user_token)

      conn = post(conn, ~p"/users/two-factor/complete", %{})

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/two-factor"
    end

    test "a challenge user cannot re-enroll TOTP to replace the factor they must prove", %{
      conn: conn
    } do
      {user, secret} = totp_login_user()

      conn = start_login(conn, user)
      assert redirected_to(conn) == ~p"/users/two-factor"

      assert {:error, {:live_redirect, %{to: "/users/two-factor"}}} =
               live(conn, ~p"/users/two-factor/setup")

      # The enrolled secret is untouched, so the real factor still authenticates.
      assert Accounts.decrypt_totp_secret(Accounts.get_user(user.id)) == secret
    end

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

      # Once this session's own secret is enrolled, completion issues the session.
      {:ok, _} = Accounts.enable_totp(admin, get_session(conn, :pending_2fa_setup_secret))
      conn = post(conn, ~p"/users/two-factor/complete", %{})
      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
    end

    # Two setup sessions for one factor-less admin: the real admin's, and one opened with a
    # stolen password. When the real admin enrolls, the other session must not be able to ride
    # that enrollment into a session token — nor overwrite it from its own setup page.
    test "a parallel setup session cannot complete on, or replace, another session's factor", %{
      conn: conn
    } do
      admin = set_password(admin_fixture())

      thief = start_login(conn, admin)
      {:ok, thief_lv, _html} = live(thief, ~p"/users/two-factor/setup")

      real = start_login(build_conn(), admin)
      real_secret = get_session(real, :pending_2fa_setup_secret)
      refute real_secret == get_session(thief, :pending_2fa_setup_secret)
      {:ok, _} = Accounts.enable_totp(admin, real_secret)

      thief_done = post(thief, ~p"/users/two-factor/complete", %{})
      refute get_session(thief_done, :user_token)

      # The thief's page confirms a code for its own secret — refused, factor untouched.
      thief_secret = get_session(thief, :pending_2fa_setup_secret)

      assert {:error, {:live_redirect, %{to: "/users/two-factor"}}} =
               thief_lv
               |> form("#totp_setup_form",
                 user: %{totp_code: NimbleTOTP.verification_code(thief_secret)}
               )
               |> render_submit()

      assert Accounts.decrypt_totp_secret(Accounts.get_user!(admin.id)) == real_secret
    end
  end
end
