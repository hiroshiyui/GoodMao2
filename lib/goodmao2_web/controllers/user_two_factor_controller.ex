defmodule Goodmao2Web.UserTwoFactorController do
  @moduledoc """
  Authoritative completion of the second-factor stage (ADR-0013).

  LiveViews can't write the session cookie, so the challenge/setup LiveViews hand off here
  via a form POST. Every action re-loads the pending-2FA user from the session
  (`UserAuth.fetch_pending_2fa_user/1`) and re-verifies the factor server-side — a stale
  socket or a crafted POST cannot skip it. Only on success does `UserAuth.complete_2fa_login/2`
  finally issue the session token.

  Failures are bounded twice. A per-session counter drops the session after `#{5}` failures —
  but the session is a client-held cookie, and replaying the pre-failure cookie resets that
  count, so it is only the friendly path. The authoritative budget is per user and server-side
  (`LoginRateLimiter.reserve_second_factor/1`): each attempt is charged before it is evaluated,
  and once the budget is spent no factor is looked at until the window passes, so a stolen
  password cannot be paired with an online TOTP brute force.
  """
  use Goodmao2Web, :controller

  require Logger

  alias Goodmao2.Accounts
  alias Goodmao2.Accounts.{LoginRateLimiter, WebAuthnChallenges}
  alias Goodmao2Web.UserAuth

  @max_attempts 5

  # --- TOTP (challenge path) ---
  def totp(conn, %{"user" => %{"totp_code" => code}}) do
    with_factor_attempt(conn, fn conn, user ->
      secret = Accounts.decrypt_totp_secret(user)

      # Verifies and claims the code's 30s window in one step, so it can't be replayed — not
      # even by a concurrent request carrying the same code.
      if is_binary(secret) and Accounts.consume_totp(user, secret, code) == :ok do
        succeed(conn, user)
      else
        fail(
          conn,
          user,
          :totp,
          ~p"/users/two-factor",
          gettext("That code is not valid. Please try again.")
        )
      end
    end)
  end

  def totp(conn, _params), do: redirect(conn, to: ~p"/users/two-factor")

  # --- Recovery code (challenge path) ---
  def recovery(conn, %{"user" => %{"recovery_code" => code}}) do
    with_factor_attempt(conn, fn conn, user ->
      case Accounts.verify_recovery_code(user, code) do
        :ok ->
          succeed(conn, user)

        :error ->
          fail(
            conn,
            user,
            :recovery_code,
            ~p"/users/two-factor/recovery",
            gettext("That recovery code is not valid or has already been used.")
          )
      end
    end)
  end

  def recovery(conn, _params), do: redirect(conn, to: ~p"/users/two-factor/recovery")

  # --- WebAuthn assertion (challenge path) ---
  def webauthn(conn, %{"webauthn" => params}) do
    with_factor_attempt(conn, fn conn, user ->
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
            user,
            :security_key,
            ~p"/users/two-factor",
            gettext("Security key verification failed. Please try again.")
          )
      end
    end)
  end

  def webauthn(conn, _params), do: redirect(conn, to: ~p"/users/two-factor")

  # --- Post-setup completion (forced-enrollment path) ---
  #
  # This is the tail of the *enrollment* flow, not a factor check — it verifies nothing. So
  # it must be reachable only from a session that entered via `:setup_required`, which
  # `:pending_2fa_setup_allowed` records. The enrolled-factor test alone is not a gate: a
  # `:challenge` user (password verified, factor already enrolled) satisfies it the instant
  # primary auth succeeds, so without the marker a stolen password alone would mint a
  # session token here with no code, key, or recovery code ever presented.
  #
  # Nor is "a factor is enrolled" enough *within* the setup flow. Every login of an admin without
  # a factor opens its own setup session, so a password thief can hold one while the real admin
  # enrolls in another; the thief's `complete` would then succeed on the admin's factor. Only the
  # TOTP secret this session was handed — and that its own page confirmed — finishes it.
  def complete(conn, _params) do
    with_pending(conn, fn conn, user ->
      setup_flow? = get_session(conn, :pending_2fa_setup_allowed) == true

      cond do
        not setup_flow? ->
          redirect(conn, to: ~p"/users/two-factor")

        enrolled_in_this_flow?(conn, user) ->
          conn
          |> put_flash(:info, gettext("Two-factor authentication is now on."))
          |> UserAuth.complete_2fa_login(user)

        true ->
          redirect(conn, to: ~p"/users/two-factor/setup")
      end
    end)
  end

  # --- helpers ---

  defp enrolled_in_this_flow?(conn, user) do
    with setup_secret when is_binary(setup_secret) <- get_session(conn, :pending_2fa_setup_secret),
         stored when is_binary(stored) <- Accounts.decrypt_totp_secret(user) do
      Plug.Crypto.secure_compare(stored, setup_secret)
    else
      _ -> false
    end
  end

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

  # A factor is only evaluated after charging it to the user's server-side budget; once that is
  # spent, the pending session is dropped without looking at the submitted code.
  defp with_factor_attempt(conn, fun) do
    with_pending(conn, fn conn, user ->
      case LoginRateLimiter.reserve_second_factor(user.id) do
        :ok -> fun.(conn, user)
        {:error, :rate_limited} -> too_many_attempts(conn, user)
      end
    end)
  end

  defp succeed(conn, user) do
    LoginRateLimiter.clear_second_factor(user.id)

    conn
    |> put_flash(:info, gettext("Welcome back!"))
    |> UserAuth.complete_2fa_login(user)
  end

  defp fail(conn, user, factor, back_to, message) do
    Logger.info(
      "auth.second_factor_failed user_id=#{user.id} factor=#{factor} " <>
        "client=#{UserAuth.client_ip(conn)}"
    )

    attempts = (get_session(conn, :pending_2fa_attempts) || 0) + 1

    if attempts >= @max_attempts do
      too_many_attempts(conn, user)
    else
      conn
      |> put_session(:pending_2fa_attempts, attempts)
      |> put_flash(:error, message)
      |> redirect(to: back_to)
    end
  end

  defp too_many_attempts(conn, user) do
    Logger.warning(
      "auth.second_factor_locked_out user_id=#{user.id} client=#{UserAuth.client_ip(conn)}"
    )

    conn
    |> configure_session(drop: true)
    |> put_flash(:error, gettext("Too many attempts. Please log in again."))
    |> redirect(to: ~p"/users/log-in")
  end
end
