defmodule Goodmao2Web.UserLive.PasswordSettingsTest do
  use Goodmao2Web.ConnCase, async: true

  alias Goodmao2.Accounts
  import Phoenix.LiveViewTest
  import Goodmao2.AccountsFixtures

  describe "Change password page" do
    test "renders the isolated change-password page", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_user(set_password(user_fixture()))
        |> live(~p"/users/settings/password")

      assert html =~ "Change password"
      assert html =~ "Current password"
      assert html =~ "New password"
      assert html =~ "Save password"
    end

    test "renders a set-password page when the account has no password", %{conn: conn} do
      # Registration is magic-link only, so a fresh account has no password at all.
      # Asking it to confirm a "current password" it does not have is nonsense, so the
      # field is omitted entirely (User.validate_current_password/2 skips the check).
      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings/password")

      assert html =~ "Set password"
      assert html =~ "no password yet"
      refute html =~ "Current password"
      assert html =~ "New password"
      assert html =~ "Save password"
    end

    test "redirects if user is not logged in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/users/settings/password")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end

    test "redirects if user is not in sudo mode", %{conn: conn} do
      {:ok, conn} =
        conn
        |> log_in_user(user_fixture(),
          token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
        )
        |> live(~p"/users/settings/password")
        |> follow_redirect(conn, ~p"/users/log-in")

      assert conn.resp_body =~ "You must re-authenticate to access this page."
    end
  end

  describe "set password (account has none)" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "sets a password without supplying a current one", %{conn: conn, user: user} do
      new_password = "a brand new valid password"
      refute user.hashed_password

      {:ok, lv, _html} = live(conn, ~p"/users/settings/password")

      form =
        form(lv, "#password_form", %{
          "user" => %{
            "email" => user.email,
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      render_submit(form)
      new_password_conn = follow_trigger_action(form, conn)

      assert redirected_to(new_password_conn) == ~p"/users/settings"

      assert Phoenix.Flash.get(new_password_conn.assigns.flash, :info) =~
               "Password updated successfully"

      assert Accounts.get_user_by_email_and_password(user.email, new_password)
    end
  end

  describe "update password" do
    setup %{conn: conn} do
      # A user with a real password so the current-password gate actually applies
      # (magic-link `user_fixture/0` has no password).
      user = set_password(user_fixture())
      %{conn: log_in_user(conn, user), user: user}
    end

    test "changes the password with the correct current password", %{conn: conn, user: user} do
      new_password = "a brand new valid password"

      {:ok, lv, _html} = live(conn, ~p"/users/settings/password")

      form =
        form(lv, "#password_form", %{
          "user" => %{
            "email" => user.email,
            "current_password" => valid_user_password(),
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      render_submit(form)

      new_password_conn = follow_trigger_action(form, conn)

      assert redirected_to(new_password_conn) == ~p"/users/settings"
      assert get_session(new_password_conn, :user_token) != get_session(conn, :user_token)

      assert Phoenix.Flash.get(new_password_conn.assigns.flash, :info) =~
               "Password updated successfully"

      assert Accounts.get_user_by_email_and_password(user.email, new_password)
    end

    test "rejects a wrong current password and does not change it", %{conn: conn, user: user} do
      new_password = "a brand new valid password"

      {:ok, lv, _html} = live(conn, ~p"/users/settings/password")

      result =
        lv
        |> form("#password_form", %{
          "user" => %{
            "email" => user.email,
            "current_password" => "not the current password",
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })
        |> render_submit()

      assert result =~ "is not valid"
      # The password is unchanged: the old one still authenticates, the new one does not.
      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
      refute Accounts.get_user_by_email_and_password(user.email, new_password)
    end

    test "renders new-password errors (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings/password")

      result =
        lv
        |> element("#password_form")
        |> render_change(%{
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })

      assert result =~ "Save password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end

    test "renders errors on submit with an invalid new password", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings/password")

      result =
        lv
        |> form("#password_form", %{
          "user" => %{
            "current_password" => valid_user_password(),
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })
        |> render_submit()

      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end
  end
end
