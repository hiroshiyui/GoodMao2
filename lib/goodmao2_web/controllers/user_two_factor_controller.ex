defmodule Goodmao2Web.UserTwoFactorController do
  @moduledoc """
  Authoritative completion of the second-factor stage (ADR-0013).

  LiveViews can't write the session cookie, so the challenge/setup LiveViews hand off here
  via a form POST. Every action re-loads the pending-2FA user from the session
  (`UserAuth.fetch_pending_2fa_user/1`) and re-verifies the factor server-side — a stale
  socket or a crafted POST cannot skip it. Only on success does `UserAuth.complete_2fa_login/2`
  finally issue the session token. A per-session attempt counter drops the session after
  `#{5}` failures.
  """
  use Goodmao2Web, :controller

  alias Goodmao2.Accounts
  alias Goodmao2.Accounts.WebAuthnChallenges
  alias Goodmao2Web.UserAuth

  @max_attempts 5

  # --- TOTP (challenge path) ---
  def totp(conn, %{"user" => %{"totp_code" => code}}) do
    with_pending(conn, fn conn, user ->
      secret = Accounts.decrypt_totp_secret(user)

      if is_binary(secret) and Accounts.valid_totp?(secret, code) do
        succeed(conn, user)
      else
        fail(conn, ~p"/users/two-factor", gettext("That code is not valid. Please try again."))
      end
    end)
  end

  def totp(conn, _params), do: redirect(conn, to: ~p"/users/two-factor")

  # --- Recovery code (challenge path) ---
  def recovery(conn, %{"user" => %{"recovery_code" => code}}) do
    with_pending(conn, fn conn, user ->
      case Accounts.verify_recovery_code(user, code) do
        :ok ->
          succeed(conn, user)

        :error ->
          fail(
            conn,
            ~p"/users/two-factor/recovery",
            gettext("That recovery code is not valid or has already been used.")
          )
      end
    end)
  end

  def recovery(conn, _params), do: redirect(conn, to: ~p"/users/two-factor/recovery")

  # --- WebAuthn assertion (challenge path) ---
  def webauthn(conn, %{"webauthn" => params}) do
    with_pending(conn, fn conn, user ->
      token = params["challenge_token"] || ""

      with {:ok, challenge} <- WebAuthnChallenges.pop(token, user.id),
           {:ok, _cred} <-
             Accounts.finish_webauthn_authentication(
               user,
               params["credential_id"],
               params["authenticator_data"],
               params["client_data_json"],
               params["signature"],
               challenge
             ) do
        succeed(conn, user)
      else
        _ ->
          fail(
            conn,
            ~p"/users/two-factor",
            gettext("Security key verification failed. Please try again.")
          )
      end
    end)
  end

  def webauthn(conn, _params), do: redirect(conn, to: ~p"/users/two-factor")

  # --- Post-setup completion (forced-enrollment path) ---
  #
  # Reachable only in the pending state; issues the session ONLY once the user actually
  # has a second factor enrolled — closing a setup-skip bypass.
  def complete(conn, _params) do
    with_pending(conn, fn conn, user ->
      if Accounts.totp_enabled?(user) or Accounts.webauthn_enabled?(user) do
        conn
        |> put_flash(:info, gettext("Two-factor authentication is now on."))
        |> UserAuth.complete_2fa_login(user)
      else
        redirect(conn, to: ~p"/users/two-factor/setup")
      end
    end)
  end

  # --- helpers ---

  defp with_pending(conn, fun) do
    case UserAuth.fetch_pending_2fa_user(conn) do
      {:ok, user} ->
        fun.(conn, user)

      :error ->
        conn
        |> put_flash(:error, gettext("Your login attempt expired. Please try again."))
        |> redirect(to: ~p"/users/log-in")
    end
  end

  defp succeed(conn, user) do
    conn
    |> put_flash(:info, gettext("Welcome back!"))
    |> UserAuth.complete_2fa_login(user)
  end

  defp fail(conn, back_to, message) do
    attempts = (get_session(conn, :pending_2fa_attempts) || 0) + 1

    if attempts >= @max_attempts do
      conn
      |> configure_session(drop: true)
      |> put_flash(:error, gettext("Too many attempts. Please log in again."))
      |> redirect(to: ~p"/users/log-in")
    else
      conn
      |> put_session(:pending_2fa_attempts, attempts)
      |> put_flash(:error, message)
      |> redirect(to: back_to)
    end
  end
end
