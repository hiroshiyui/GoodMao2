defmodule Goodmao2Web.Features.SessionRevocationTest do
  @moduledoc """
  A revoked session's open page leaves promptly, driven through two real browsers.

  `UserAuth.disconnect_sessions/1` is covered at the PubSub level in `user_auth_test.exs`,
  which proves the `"disconnect"` broadcast is sent. What only a browser can prove is what the
  client does with it: Phoenix closes the socket, LiveView reconnects, and the auth `on_mount`
  sends the dead session to the login page. That chain depends on the WebSocket close code
  Phoenix sends. 1.8.16 stopped sending 1001 (phoenixframework/phoenix PR 6880), Bandit then
  closes with 1000, and LiveView's client treats 1000 as a failsafe: a full reload after a
  5–10 s random delay instead of an immediate reconnect, so the revoked browser lingers on a
  dead page. Phoenix is held at 1.8.15 until a reconnect follows the close; this test is the
  gate for lifting the hold (`wait_for_path/2` allows five seconds).
  """
  use Goodmao2Web.FeatureCase, async: false

  @moduletag :feature

  @new_password "another fine password!"

  feature "changing the password sends the other browser's open page to the login page", %{
    session: session
  } do
    user = browser_user_fixture()

    other_device =
      start_another_session()
      |> log_in_via_browser(user)
      |> assert_has(Query.css("#pets-heading"))

    # A fresh login is in sudo mode, so the password form accepts the change outright.
    session
    |> log_in_via_browser(user)
    |> visit("/users/settings/password")
    |> fill_in(Query.css("#password_form input[name='user[current_password]']"),
      with: valid_user_password()
    )
    |> fill_in(Query.css("#password_form input[name='user[password]']"), with: @new_password)
    |> fill_in(Query.css("#password_form input[name='user[password_confirmation]']"),
      with: @new_password
    )
    |> click(Query.css("#password_form button[type=submit]"))
    |> wait_for_path("/users/settings")

    # The change rotated every session token and broadcast "disconnect" to each; the other
    # browser must reach the login page without a reload-with-jitter delay.
    wait_for_path(other_device, "/users/log-in")
  end
end
