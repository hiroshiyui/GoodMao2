defmodule Goodmao2Web.Features.TwoFactorTest do
  @moduledoc """
  The second factor driven end to end (ADR-0013).

  The TOTP half is covered against the LiveView elsewhere; what a browser adds is that the
  challenge page is reached with no session token yet, and that submitting it lands the user
  signed in.

  The security-key half has no other coverage at all. `Accounts.WebAuthn` is exercised in the
  context tests against recorded ceremony fixtures, and `webauthn_credential_fixture/2` inserts
  a row directly — neither runs the browser side, so the `WebAuthn` hook, the CBOR the client
  actually produces, and the origin check are untested. A WebDriver virtual authenticator
  performs a real ceremony without hardware.
  """
  use Goodmao2Web.FeatureCase, async: false

  @moduletag :feature

  alias Goodmao2.Accounts

  feature "signs in through the authenticator challenge", %{session: session} do
    user = browser_user_fixture()
    secret = Accounts.generate_totp_secret()
    {:ok, user} = Accounts.enable_totp(user, secret)

    session
    |> log_in_with_totp_via_browser(user, secret)
    |> assert_has(Query.css("#pets-heading"))
  end

  feature "refuses a wrong authenticator code", %{session: session} do
    user = browser_user_fixture()
    secret = Accounts.generate_totp_secret()
    {:ok, user} = Accounts.enable_totp(user, secret)

    session =
      session
      |> submit_login_form(user.email, valid_user_password())
      |> assert_has(Query.css("#totp_challenge_form"))
      |> fill_in(Query.css("#totp_challenge_form input[name='user[totp_code]']"), with: "000000")
      |> click(Query.css("#totp-challenge-submit"))

    # Still challenged, and not signed in.
    assert_has(session, Query.css("#totp_challenge_form"))
    refute_has(session, Query.css("#pets-heading"))
  end

  feature "registers a security key through a real WebAuthn ceremony", %{session: session} do
    user = browser_user_fixture()

    {session, _authenticator_id} = add_virtual_authenticator(session)

    session =
      session
      |> log_in_via_browser(user)
      |> visit("/users/settings/two-factor")
      |> assert_has(Query.css("#security-keys-empty"))
      |> click(Query.css("#add-security-key"))

    # The credential only lands if the browser produced a real attestation and `Wax` accepted
    # its origin -- which is why FeatureCase points the wax_ origin at Wallaby's base_url.
    assert_has(session, Query.css("#security-keys-list"))
    assert Accounts.webauthn_enabled?(user)
  end
end
