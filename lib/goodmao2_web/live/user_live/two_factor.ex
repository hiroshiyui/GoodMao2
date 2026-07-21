defmodule Goodmao2Web.UserLive.TwoFactor do
  @moduledoc """
  The second-factor challenge shown after primary auth for a user who has a factor
  enrolled (ADR-0013).

  The user holds no session token yet (`:require_pending_2fa`). TOTP and recovery codes
  submit via native form POSTs to `Goodmao2Web.UserTwoFactorController`, which verifies
  authoritatively; the security-key option runs a WebAuthn assertion in the browser
  (`WebAuthn` JS hook) and submits the hidden form.
  """
  use Goodmao2Web, :live_view

  alias Goodmao2.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-4" id="two-factor-challenge">
        <div class="text-center">
          <.header>
            {gettext("Two-step verification")}
            <:subtitle>{gettext("Confirm it's you to finish signing in.")}</:subtitle>
          </.header>
        </div>

        <section :if={@totp?} aria-labelledby="totp-challenge-heading" id="totp-challenge">
          <h2 id="totp-challenge-heading" class="sr-only">
            {gettext("Authenticator code")}
          </h2>
          <.form
            for={@totp_form}
            id="totp_challenge_form"
            action={~p"/users/two-factor/totp"}
            method="post"
          >
            <.input
              field={@totp_form[:totp_code]}
              type="text"
              label={gettext("Authenticator code")}
              inputmode="numeric"
              autocomplete="one-time-code"
              pattern="[0-9]*"
              maxlength="6"
              required
              phx-mounted={JS.focus()}
            />
            <.button class="btn btn-primary w-full" id="totp-challenge-submit">
              {gettext("Verify")}
            </.button>
          </.form>
        </section>

        <div :if={@totp? and @webauthn?} class="divider">{gettext("or")}</div>

        <section :if={@webauthn?} aria-labelledby="webauthn-challenge-heading" id="webauthn-challenge">
          <h2 id="webauthn-challenge-heading" class="sr-only">
            {gettext("Security key")}
          </h2>
          <.button
            type="button"
            class="btn btn-outline w-full"
            id="webauthn-challenge-button"
            phx-click="begin_webauthn"
          >
            <.icon name="hero-key" class="size-5" /> {gettext("Use a security key")}
          </.button>

          <form
            id="webauthn_challenge_form"
            action={~p"/users/two-factor/webauthn"}
            method="post"
            phx-hook="WebAuthn"
            class="hidden"
          >
            <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
            <input type="hidden" name="webauthn[challenge_token]" value={@challenge_token} />
            <input type="hidden" name="webauthn[credential_id]" data-webauthn="credential_id" />
            <input
              type="hidden"
              name="webauthn[authenticator_data]"
              data-webauthn="authenticator_data"
            />
            <input type="hidden" name="webauthn[client_data_json]" data-webauthn="client_data_json" />
            <input type="hidden" name="webauthn[signature]" data-webauthn="signature" />
          </form>
        </section>

        <div class="flex justify-between text-sm">
          <.link
            :if={@totp? or @webauthn?}
            navigate={~p"/users/two-factor/recovery"}
            id="use-recovery-code-link"
            class="link link-primary"
          >
            {gettext("Use a recovery code")}
          </.link>
          <.link href={~p"/users/log-in"} method="get" id="two-factor-cancel" class="link">
            {gettext("Start over")}
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.pending_2fa_user

    socket =
      socket
      |> assign(:page_title, gettext("Two-step verification"))
      |> assign(:totp?, Accounts.totp_enabled?(user))
      |> assign(:webauthn?, Accounts.webauthn_enabled?(user))
      |> assign(:challenge_token, "")
      |> assign(:totp_form, to_form(%{"totp_code" => ""}, as: "user"))

    {:ok, socket}
  end

  @impl true
  def handle_event("begin_webauthn", _params, socket) do
    {token, options} = Accounts.begin_webauthn_authentication(socket.assigns.pending_2fa_user)

    {:noreply,
     socket
     |> assign(:challenge_token, token)
     |> push_event("webauthn_authenticate", %{options: options})}
  end
end
