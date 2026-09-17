defmodule Goodmao2Web.UserSessionController do
  use Goodmao2Web, :controller

  require Logger

  alias Goodmao2.Accounts
  alias Goodmao2.Accounts.LoginRateLimiter
  alias Goodmao2Web.UserAuth

  # `User.email_changeset/3` caps an address at 160 characters. The byte bound leaves room for
  # multi-byte addresses while refusing a megabyte-sized value before the limiter or DB see it.
  @max_email_bytes 1024

  def create(conn, %{"_action" => "confirmed"} = params) do
    create(conn, params, gettext("User confirmed successfully."))
  end

  def create(conn, params) do
    create(conn, params, gettext("Welcome back!"))
  end

  # magic link login
  defp create(conn, %{"user" => %{"token" => token} = user_params}, info) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, tokens_to_disconnect}} ->
        UserAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_or_challenge(user, user_params)

      _ ->
        Logger.info("auth.magic_link_rejected client=#{UserAuth.client_ip(conn)}")

        conn
        |> put_flash(:error, gettext("The link is invalid or it has expired."))
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # email + password login
  defp create(conn, %{"user" => %{"email" => email, "password" => password} = user_params}, info)
       when is_binary(email) and is_binary(password) and byte_size(email) <= @max_email_bytes do
    # Throttle online password guessing. A rate-limited attempt returns the same generic error
    # as a wrong password, so it leaks nothing about whether the address exists or is locked.
    with :ok <- LoginRateLimiter.check(email),
         user when not is_nil(user) <- Accounts.get_user_by_email_and_password(email, password) do
      LoginRateLimiter.clear(email)

      conn
      |> put_flash(:info, info)
      |> UserAuth.log_in_or_challenge(user, user_params)
    else
      _ ->
        # Only spend a failure slot on a genuine bad-password attempt (not on an already
        # rate-limited request), so a locked-out attacker can't keep extending the window.
        # The log names no address: it is attacker-chosen, and for a real account it is PII.
        if LoginRateLimiter.check(email) == :ok do
          LoginRateLimiter.record_failure(email)
          Logger.info("auth.login_failed client=#{UserAuth.client_ip(conn)}")
        else
          Logger.warning("auth.login_rate_limited client=#{UserAuth.client_ip(conn)}")
        end

        # Don't disclose whether the email is registered (user-enumeration defense).
        invalid_credentials(conn, email)
    end
  end

  # A missing, non-string, or oversized email identifies no one, so it gets the same generic
  # answer without reaching the limiter or the database.
  defp create(conn, params, _info) do
    email =
      case params do
        %{"user" => %{"email" => email}} when is_binary(email) -> email
        _ -> ""
      end

    invalid_credentials(conn, email)
  end

  defp invalid_credentials(conn, email) do
    conn
    |> put_flash(:error, gettext("Invalid email or password"))
    |> put_flash(:email, String.slice(email, 0, 160))
    |> redirect(to: ~p"/users/log-in")
  end

  def update_password(conn, %{"user" => user_params}) do
    user = conn.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)
    current_password = user_params["current_password"]

    # Authoritative gate: re-verify the current password here (not only in the
    # LiveView) so a direct POST can't bypass it.
    case Accounts.update_user_password(user, current_password, user_params) do
      {:ok, {user, expired_tokens}} ->
        # disconnect all existing LiveViews with old sessions
        UserAuth.disconnect_sessions(expired_tokens)

        # The user is already fully authenticated (they are in sudo mode and just
        # re-entered their password), so re-issue the session directly rather than
        # routing through the login flow — no fresh 2FA challenge here.
        conn
        |> put_session(:user_return_to, ~p"/users/settings")
        |> put_flash(:info, gettext("Password updated successfully!"))
        |> UserAuth.log_in_user(user, user_params)

      {:error, _changeset} ->
        conn
        |> put_flash(
          :error,
          gettext("Current password is not valid, or the new password is invalid.")
        )
        |> redirect(to: ~p"/users/settings/password")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, gettext("Logged out successfully."))
    |> UserAuth.log_out_user()
  end
end
