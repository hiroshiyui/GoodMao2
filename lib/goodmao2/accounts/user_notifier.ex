defmodule Goodmao2.Accounts.UserNotifier do
  @moduledoc """
  Transactional account emails: confirmation, magic-link login, email-change, and password
  reset. Every one carries a single-use, expiring token minted by `UserToken` — the body is
  the only place the raw token ever appears, since only its hash is stored.
  """
  import Swoosh.Email

  alias Goodmao2.Mailer
  alias Goodmao2.Accounts.User

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from(Application.fetch_env!(:goodmao2, :mailer_from))
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Update email instructions", """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    deliver(user.email, "Log in instructions", """

    ==============================

    Hi #{user.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Confirmation instructions", """

    ==============================

    Hi #{user.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """)
  end

  # What each security notice says changed (`Goodmao2.Accounts.SecurityNoticeWorker`).
  @security_events %{
    "password_changed" => "your password was changed",
    "email_changed" => "the email address on your account was changed",
    "totp_enabled" => "an authenticator app was set up for two-factor sign-in",
    "totp_disabled" => "two-factor sign-in with an authenticator app was turned off",
    "security_key_added" => "a security key was added for two-factor sign-in",
    "security_key_removed" => "a security key was removed from two-factor sign-in",
    "recovery_codes_generated" => "new two-factor recovery codes were generated",
    "recovery_code_used" => "a recovery code was used to sign in"
  }

  @doc "The security events a notice can be sent for."
  def security_events, do: Map.keys(@security_events)

  @doc """
  Tells `recipient` that a security setting on their account changed. No link and no token —
  a phished copy of this mail grants nothing.
  """
  def deliver_security_notice(recipient, event, %DateTime{} = at)
      when is_map_key(@security_events, event) do
    deliver(recipient, "Security notice: your GoodMao account changed", """

    ==============================

    Hi,

    On #{Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")}, #{Map.fetch!(@security_events, event)}.

    If this was you, there is nothing to do.

    If it was not, sign in and change your password at once, then review two-factor sign-in
    on your account settings page, or ask the site administrator for help.

    ==============================
    """)
  end

  def deliver_security_notice(recipient, event, %NaiveDateTime{} = at),
    do: deliver_security_notice(recipient, event, DateTime.from_naive!(at, "Etc/UTC"))
end
