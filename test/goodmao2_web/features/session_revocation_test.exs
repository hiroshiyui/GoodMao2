defmodule Goodmao2Web.Features.SessionRevocationTest do
  @moduledoc """
  A revoked session's open page leaves promptly, driven through two real browsers.

  `UserAuth.disconnect_sessions/1` and its revocation hook are covered in `user_auth_test.exs`
  against the LiveView process. What only a browser can prove is that the page really leaves:
  the redirect has to reach the client before the delayed `"disconnect"` closes the socket.
  Without the hook, the close alone decides, and since Phoenix 1.8.16 (PR 6880) that close is
  code 1000, which LiveView's client answers with a reload after a 5–10 s random delay, so the
  revoked browser would linger on a dead page (`wait_for_path/2` allows five seconds).
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
