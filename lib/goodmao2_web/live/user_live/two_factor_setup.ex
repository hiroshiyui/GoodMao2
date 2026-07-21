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
            <.button class="btn btn-primary w-full" id="recovery-codes-continue">
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
    user = socket.assigns.pending_2fa_user
    secret = session["pending_2fa_setup_secret"] || Accounts.generate_totp_secret()
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
  end

  @impl true
  def handle_event("confirm", %{"user" => %{"totp_code" => code}}, socket) do
    user = socket.assigns.pending_2fa_user
    secret = socket.assigns.secret

    if Accounts.valid_totp?(secret, code) do
      {:ok, user} = Accounts.enable_totp(user, secret)
      codes = Accounts.generate_recovery_codes(user)

      {:noreply,
       socket
       |> assign(:pending_2fa_user, user)
       |> assign(:step, :show_codes)
       |> assign(:recovery_codes, codes)}
    else
      {:noreply, put_flash(socket, :error, gettext("That code is not valid. Please try again."))}
    end
  end
end
