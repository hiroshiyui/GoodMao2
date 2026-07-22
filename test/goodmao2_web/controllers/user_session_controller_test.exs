defmodule Goodmao2Web.UserSessionControllerTest do
  use Goodmao2Web.ConnCase, async: true

  import Goodmao2.AccountsFixtures
  alias Goodmao2.Accounts

  setup do
    # Take the admin seat first so the fixtures below are ordinary non-admin users — an
    # admin with no second factor is forced into 2FA setup on login (ADR-0013), covered by
    # the dedicated two-factor tests.
    admin_fixture()
    %{unconfirmed_user: unconfirmed_user_fixture(), user: user_fixture()}
  end

  describe "POST /users/log-in - email and password" do
    test "logs the user in", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/pets")
      response = html_response(conn, 200)
      assert response =~ user.email
      assert response =~ ~p"/users/settings"
      assert response =~ ~p"/users/log-out"
    end

    test "logs the user in with remember me", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password(),
            "remember_me" => "true"
          }
        })

      assert conn.resp_cookies["_goodmao2_web_user_remember_me"]
      assert redirected_to(conn) == ~p"/"
    end

    test "logs the user in with return to", %{conn: conn, user: user} do
      user = set_password(user)

      conn =
        conn
        |> init_test_session(user_return_to: "/foo/bar")
        |> post(~p"/users/log-in", %{
          "user" => %{
            "email" => user.email,
            "password" => valid_user_password()
          }
        })

      assert redirected_to(conn) == "/foo/bar"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome back!"
    end

    test "redirects to login page with invalid credentials", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/users/log-in?mode=password", %{
          "user" => %{"email" => user.email, "password" => "invalid_password"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "POST /users/log-in - password rate limiting" do
    # Matches config :goodmao2, Goodmao2.Accounts, :login_attempts_per_hour.
    @attempts_per_hour 10

    test "locks out after too many failures, refusing even the correct password", %{
      conn: conn,
      user: user
    } do
      user = set_password(user)

      for _ <- 1..@attempts_per_hour do
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => "wrong-password"}
        })
      end

      # The correct password is now refused with the same generic error (no lockout oracle).
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      refute get_session(conn, :user_token)
    end

    test "a successful login clears the failure counter", %{conn: conn, user: user} do
      user = set_password(user)

      for _ <- 1..(@attempts_per_hour - 1) do
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => "wrong-password"}
        })
      end

      # A success just under the cap resets the counter...
      ok_conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert get_session(ok_conn, :user_token)

      # ...so a fresh burst of failures does not immediately trip the limit.
      for _ <- 1..(@attempts_per_hour - 1) do
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => "wrong-password"}
        })
      end

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert get_session(conn, :user_token)
    end
  end

  describe "POST /users/log-in - magic link" do
    test "logs the user in", %{conn: conn, user: user} do
      {token, _hashed_token} = generate_user_magic_link_token(user)

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => token}
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/pets")
      response = html_response(conn, 200)
      assert response =~ user.email
      assert response =~ ~p"/users/settings"
      assert response =~ ~p"/users/log-out"
    end

    test "confirms unconfirmed user", %{conn: conn, unconfirmed_user: user} do
      {token, _hashed_token} = generate_user_magic_link_token(user)
      refute user.confirmed_at

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => token},
          "_action" => "confirmed"
        })

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "User confirmed successfully."

      assert Accounts.get_user!(user.id).confirmed_at

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/pets")
      response = html_response(conn, 200)
      assert response =~ user.email
      assert response =~ ~p"/users/settings"
      assert response =~ ~p"/users/log-out"
    end

    test "a user with 2FA is challenged, not logged in (no magic-link bypass)", %{conn: conn} do
      {user, _secret} = totp_user_fixture()

      {token, _hashed_token} = generate_user_magic_link_token(user)

      conn = post(conn, ~p"/users/log-in", %{"user" => %{"token" => token}})

      # No session token yet — the second factor still gates the login.
      refute get_session(conn, :user_token)
      assert get_session(conn, :pending_2fa_user_id) == user.id
      assert redirected_to(conn) == ~p"/users/two-factor"
    end

    test "redirects to login page when magic link is invalid", %{conn: conn} do
      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"token" => "invalid"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "The link is invalid or it has expired."

      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "DELETE /users/log-out" do
    test "logs the user out", %{conn: conn, user: user} do
      conn = conn |> log_in_user(user) |> delete(~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end

    test "succeeds even if the user is not logged in", %{conn: conn} do
      conn = delete(conn, ~p"/users/log-out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end
  end

  describe "POST /users/update-password (authoritative current-password gate)" do
    setup %{user: user} do
      %{user: set_password(user)}
    end

    test "changes the password with the correct current password", %{conn: conn, user: user} do
      new_password = "a brand new valid password"

      conn =
        conn
        |> log_in_user(user)
        |> post(~p"/users/update-password", %{
          "user" => %{
            "email" => user.email,
            "current_password" => valid_user_password(),
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Password updated successfully"
      assert Accounts.get_user_by_email_and_password(user.email, new_password)
    end

    test "rejects a direct POST with a wrong current password", %{conn: conn, user: user} do
      new_password = "a brand new valid password"

      conn =
        conn
        |> log_in_user(user)
        |> post(~p"/users/update-password", %{
          "user" => %{
            "email" => user.email,
            "current_password" => "not the current password",
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      assert redirected_to(conn) == ~p"/users/settings/password"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Current password is not valid"
      # unchanged: old password still works, new one does not
      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
      refute Accounts.get_user_by_email_and_password(user.email, new_password)
    end
  end
end
