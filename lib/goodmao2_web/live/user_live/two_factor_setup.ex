defmodule Goodmao2Web.UserLive.TwoFactorSetup do
  @moduledoc """
  Forced second-factor enrollment shown when a user who is *required* to have a second
  factor (the admin) logs in without one (ADR-0013).

  The pending setup secret is stashed in the session by
  `Goodmao2Web.UserAuth.log_in_or_challenge/3` (so it survives a socket reconnect) and read
  here at mount. Step 1 shows the QR and confirms a code — enabling TOTP and generating
  recovery codes. Step 2 shows the codes once, then a native form POST to
  `UserTwoFactorController.complete/2` issues the session.
  """
  use Goodmao2Web, :live_view

  alias Goodmao2.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-md space-y-4" id="two-factor-setup">
        <div class="text-center">
          <.header>
            {gettext("Set up two-step verification")}
            <:subtitle>
              {gettext("Your account requires a second factor. Add an authenticator app to continue.")}
            </:subtitle>
          </.header>
        </div>

        <section :if={@step == :enroll} aria-labelledby="totp-enroll-heading" id="totp-enroll">
          <h2 id="totp-enroll-heading" class="font-semibold">
            {gettext("1. Scan this QR code")}
          </h2>
          <p class="text-sm opacity-80">
            {gettext(
              "Scan it with an authenticator app (e.g. Google Authenticator, Aegis, 1Password)."
            )}
          </p>
          <img
            src={@qr_data_uri}
            alt={gettext("TOTP setup QR code")}
            id="totp-qr"
            class="mx-auto my-4 rounded bg-white p-2"
            width="264"
            height="264"
          />
          <p class="text-sm">
            {gettext("Or enter this key manually:")}
            <code id="totp-secret-text" class="break-all font-mono">{@secret_base32}</code>
          </p>

          <h2 class="mt-6 font-semibold">{gettext("2. Enter the 6-digit code")}</h2>
          <.form for={@totp_form} id="totp_setup_form" phx-submit="confirm">
            <.input
              field={@totp_form[:totp_code]}
              type="text"
              label={gettext("Authenticator code")}
              inputmode="numeric"
              autocomplete="one-time-code"
              pattern="[0-9]*"
              maxlength="6"
              required
            />
            <.button
              type="submit"
              class="btn btn-primary w-full"
              id="totp-setup-submit"
              phx-disable-with={gettext("Verifying...")}
            >
              {gettext("Turn on two-step verification")}
            </.button>
          </.form>
        </section>

        <section
          :if={@step == :show_codes}
          aria-labelledby="recovery-codes-heading"
          id="recovery-codes"
        >
          <h2 id="recovery-codes-heading" class="font-semibold">
            {gettext("Save your recovery codes")}
          </h2>
          <p class="text-sm opacity-80">
            {gettext(
              "Store these somewhere safe. Each code works once if you lose your authenticator. They won't be shown again."
            )}
          </p>
          <ul id="recovery-codes-list" class="my-4 grid grid-cols-2 gap-2 font-mono text-sm">
            <li :for={code <- @recovery_codes} class="rounded bg-base-200 px-2 py-1 text-center">
              {code}
            </li>
          </ul>
          <form action={~p"/users/two-factor/complete"} method="post">
            <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
            <.button type="submit" class="btn btn-primary w-full" id="recovery-codes-continue">
              {gettext("I saved my codes — continue")}
            </.button>
          </form>
        </section>

        <div class="text-center text-sm">
          <.link href={~p"/users/log-in"} method="get" id="two-factor-setup-cancel" class="link">
            {gettext("Start over")}
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, session, socket) do
    # Enrollment is only for a session that entered via `:setup_required`. A `:challenge`
    # user reaching here would be handed a *fresh* secret, and confirming it calls
    # `enable_totp/2`, silently replacing the factor they were supposed to be proving —
    # and wiping the recovery codes with it. Password alone must never re-enroll a factor.
    #
    # The secret must be the session's own: `UserTwoFactorController.complete/2` only finishes
    # an enrollment of exactly that secret, so one invented here could never complete.
    with true <- session["pending_2fa_setup_allowed"] == true,
         secret when is_binary(secret) <- session["pending_2fa_setup_secret"] do
      user = socket.assigns.pending_2fa_user
      uri = Accounts.totp_uri(secret, user.email)

      socket =
        socket
        |> assign(:page_title, gettext("Set up two-step verification"))
        |> assign(:step, :enroll)
        |> assign(:secret, secret)
        |> assign(:secret_base32, Base.encode32(secret, padding: false))
        |> assign(:qr_data_uri, Accounts.totp_qr_data_uri(uri))
        |> assign(:recovery_codes, [])
        |> assign(:totp_form, to_form(%{"totp_code" => ""}, as: "user"))

      {:ok, socket}
    else
      _ -> {:ok, push_navigate(socket, to: ~p"/users/two-factor")}
    end
  end

  @impl true
  def handle_event("confirm", %{"user" => %{"totp_code" => code}}, socket) do
    # Re-read: another setup session for this account (another tab — or someone else holding
    # the password) may have enrolled since this page mounted. Enrolling over it would replace a
    # factor this session never proved, so the existing factor must be used to sign in instead.
    user = Accounts.get_user!(socket.assigns.pending_2fa_user.id)
    secret = socket.assigns.secret

    cond do
      Accounts.totp_enabled?(user) or Accounts.webauthn_enabled?(user) ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("Two-step verification is already set up for this account. Use it to sign in.")
         )
         |> push_navigate(to: ~p"/users/two-factor")}

      is_binary(code) and Accounts.valid_totp?(secret, code) ->
        {:ok, user} = Accounts.enable_totp(user, secret)
        codes = Accounts.generate_recovery_codes(user)

        {:noreply,
         socket
         |> assign(:pending_2fa_user, user)
         |> assign(:step, :show_codes)
         |> assign(:recovery_codes, codes)}

      true ->
        {:noreply,
         put_flash(socket, :error, gettext("That code is not valid. Please try again."))}
    end
  end
end
