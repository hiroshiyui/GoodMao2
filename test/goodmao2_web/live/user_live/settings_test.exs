defmodule Goodmao2Web.UserLive.SettingsTest do
  use Goodmao2Web.ConnCase, async: true

  alias Goodmao2.Accounts
  import Phoenix.LiveViewTest
  import Goodmao2.AccountsFixtures

  describe "Settings page" do
    test "renders settings page", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings")

      assert html =~ "Change Email"
      # Password is no longer changed here — it lives on its own gated page.
      refute html =~ "Save Password"
      assert html =~ "Change password"
      assert html =~ ~p"/users/settings/password"
    end

    test "redirects if user is not logged in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/users/settings")

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
        |> live(~p"/users/settings")
        |> follow_redirect(conn, ~p"/users/log-in")

      assert conn.resp_body =~ "You must re-authenticate to access this page."
    end
  end

  describe "preferred timezone (ADR-0018)" do
    test "renders the timezone select in the profile form", %{conn: conn} do
      {:ok, _lv, html} = conn |> log_in_user(user_fixture()) |> live(~p"/users/settings")
      assert html =~ ~s(id="user-timezone-select")
      assert html =~ "Asia/Taipei"
    end

    test "saving a valid zone persists the preference", %{conn: conn} do
      user = user_fixture()
      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/users/settings")

      lv
      |> form("#profile_form", user: %{timezone: "Asia/Taipei"})
      |> render_submit()

      assert Accounts.get_user!(user.id).timezone == "Asia/Taipei"
    end

    test "a blank selection clears the preference back to the site default", %{conn: conn} do
      {:ok, user} =
        Accounts.update_user_profile(user_fixture(), %{"timezone" => "Asia/Taipei"})

      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/users/settings")

      lv |> form("#profile_form", user: %{timezone: ""}) |> render_submit()

      assert Accounts.get_user!(user.id).timezone == nil
    end

    test "an invalid zone is rejected at the changeset boundary" do
      # The <select> can only submit offered options, so junk can't arrive via the form; the
      # context guard is the backstop for any other caller.
      assert {:error, changeset} =
               Accounts.update_user_profile(user_fixture(), %{"timezone" => "Bogus/Zone"})

      assert {"is not a valid timezone", _} = changeset.errors[:timezone]
    end
  end

  describe "push notifications card" do
    test "is hidden when VAPID is not configured", %{conn: conn} do
      {:ok, _lv, html} = conn |> log_in_user(user_fixture()) |> live(~p"/users/settings")
      refute html =~ "Push notifications"
      refute html =~ ~s(phx-hook="PushManager")
    end

    test "is shown once VAPID keys exist", %{conn: conn} do
      {public_key, encrypted_private} = Goodmao2.Notifications.WebPush.generate_keypair()
      {:ok, _} = Goodmao2.Settings.put("vapid_public_key", public_key)

      {:ok, _} =
        Goodmao2.Settings.put("vapid_private_key_encrypted", Base.encode64(encrypted_private))

      {:ok, _lv, html} = conn |> log_in_user(user_fixture()) |> live(~p"/users/settings")
      assert html =~ "Push notifications"
      assert html =~ ~s(phx-hook="PushManager")
    end
  end

  describe "update email form" do
    setup %{conn: conn} do
      # Set a password so the current-password gate on the email change applies
      # (magic-link `user_fixture/0` has no password).
      user = set_password(user_fixture())
      %{conn: log_in_user(conn, user), user: user}
    end

    test "updates the user email with the correct current password", %{conn: conn, user: user} do
      new_email = unique_user_email()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{"email" => new_email, "current_password" => valid_user_password()}
        })
        |> render_submit()

      assert result =~ "A link to confirm your email"
      assert Accounts.get_user_by_email(user.email)
    end

    test "does not send the email change with a wrong current password", %{conn: conn, user: user} do
      new_email = unique_user_email()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{"email" => new_email, "current_password" => "not the current password"}
        })
        |> render_submit()

      refute result =~ "A link to confirm your email"
      assert result =~ "is not valid"
      # unchanged, and no confirmation was delivered
      assert Accounts.get_user_by_email(user.email)
      refute Accounts.get_user_by_email(new_email)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#email_form")
        |> render_change(%{
          "action" => "update_email",
          "user" => %{"email" => "with spaces"}
        })

      assert result =~ "Change Email"
      assert result =~ "must have the @ sign and no spaces"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{"email" => user.email, "current_password" => valid_user_password()}
        })
        |> render_submit()

      assert result =~ "Change Email"
      assert result =~ "did not change"
    end
  end

  describe "confirm email" do
    setup %{conn: conn} do
      user = user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{conn: log_in_user(conn, user), token: token, email: email, user: user}
    end

    test "updates the user email once", %{conn: conn, user: user, token: token, email: email} do
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")

      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"info" => message} = flash
      assert message == "Email changed successfully."
      refute Accounts.get_user_by_email(user.email)
      assert Accounts.get_user_by_email(email)

      # use confirm token again
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
    end

    test "does not update email with invalid token", %{conn: conn, user: user} do
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/oops")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
      assert Accounts.get_user_by_email(user.email)
    end

    test "redirects if user is not logged in", %{token: token} do
      conn = build_conn()
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")
      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => message} = flash
      assert message == "You must log in to access this page."
    end
  end
end
