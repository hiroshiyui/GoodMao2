defmodule Goodmao2Web.UserLive.TwoFactorSettings do
  @moduledoc """
  Sudo-gated management of a user's second factors (ADR-0013): the authenticator app
  (TOTP), hardware security keys (WebAuthn), and recovery codes.

  Because the user is already logged in here, everything runs inside the LiveView — TOTP
  enrollment holds the setup secret in a socket assign, and security-key registration
  finishes via a `pushEvent` callback from the `WebAuthn` JS hook (no controller round-trip,
  live list update). Removing the admin's last remaining factor is refused
  (`Accounts.can_remove_second_factor?/2`).
  """
  use Goodmao2Web, :live_view

  on_mount {Goodmao2Web.UserAuth, :require_sudo_mode}

  alias Goodmao2.Accounts
  alias Goodmao2.Accounts.Scope

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      unread_notifications={@unread_notifications}
      unread_messages={@unread_messages}
    >
      <div class="mx-auto max-w-lg space-y-6" id="two-factor-settings">
        <div class="text-center">
          <.header>
            {gettext("Two-factor authentication")}
            <:subtitle>{gettext("Require a second step when signing in.")}</:subtitle>
          </.header>
        </div>

        <%!-- Authenticator app (TOTP) --%>
        <section aria-labelledby="totp-heading" id="totp-settings" class="space-y-3">
          <h2 id="totp-heading" class="font-semibold">{gettext("Authenticator app")}</h2>

          <div :if={@totp_enabled? and is_nil(@totp_setup)} id="totp-status-on">
            <p class="text-success flex items-center gap-2 text-sm">
              <.icon name="hero-check-circle" class="size-5" /> {gettext("Authenticator app is on.")}
            </p>
            <.button
              type="button"
              class="btn btn-outline btn-error btn-sm mt-2"
              id="totp-disable"
              phx-click="disable_totp"
              data-confirm={
                gettext("Turn off the authenticator app? You'll no longer be asked for a code.")
              }
            >
              {gettext("Turn off")}
            </.button>
          </div>

          <div :if={not @totp_enabled? and is_nil(@totp_setup)} id="totp-status-off">
            <p class="text-base-content/60 text-sm">
              {gettext("Use an app like Google Authenticator, Aegis, or 1Password to generate codes.")}
            </p>
            <.button
              type="button"
              class="btn btn-primary btn-sm mt-2"
              id="totp-begin"
              phx-click="begin_totp_setup"
            >
              {gettext("Set up authenticator app")}
            </.button>
          </div>

          <div :if={@totp_setup} id="totp-enroll">
            <p class="text-sm">
              {gettext("Scan this QR code, then enter the 6-digit code to confirm.")}
            </p>
            <img
              src={@totp_setup.qr_data_uri}
              alt={gettext("TOTP setup QR code")}
              id="totp-settings-qr"
              class="mx-auto my-3 rounded bg-white p-2"
              width="264"
              height="264"
            />
            <p class="text-sm">
              {gettext("Or enter this key manually:")}
              <code id="totp-settings-secret" class="break-all font-mono">{@totp_setup.secret_base32}</code>
            </p>
            <.form for={@totp_form} id="totp_enable_form" phx-submit="enable_totp" class="mt-2">
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
              <div class="flex gap-2">
                <.button variant="primary" id="totp-enable" phx-disable-with={gettext("Verifying...")}>
                  {gettext("Turn on")}
                </.button>
                <.button
                  type="button"
                  class="btn btn-ghost"
                  id="totp-cancel"
                  phx-click="cancel_totp_setup"
                >
                  {gettext("Cancel")}
                </.button>
              </div>
            </.form>
          </div>
        </section>

        <div class="divider" />

        <%!-- Security keys (WebAuthn) --%>
        <section aria-labelledby="keys-heading" id="security-keys-settings" class="space-y-3">
          <h2 id="keys-heading" class="font-semibold">{gettext("Security keys")}</h2>
          <p class="text-base-content/60 text-sm">
            {gettext("Use a hardware security key or your device's built-in authenticator.")}
          </p>

          <ul :if={@credentials != []} id="security-keys-list" class="divide-y divide-base-200">
            <li
              :for={cred <- @credentials}
              id={"security-key-#{cred.id}"}
              class="flex items-center justify-between py-2"
            >
              <span class="text-sm">
                <.icon name="hero-key" class="size-4" />
                {if cred.label == "", do: gettext("Security key"), else: cred.label}
                <span :if={cred.last_used_at} class="text-base-content/50">
                  · {gettext("last used %{when}",
                    when: Calendar.strftime(cred.last_used_at, "%Y-%m-%d")
                  )}
                </span>
              </span>
              <.button
                type="button"
                class="btn btn-ghost btn-xs text-error"
                id={"security-key-delete-#{cred.id}"}
                phx-click="delete_key"
                phx-value-id={cred.id}
                data-confirm={gettext("Remove this security key?")}
                aria-label={gettext("Remove security key")}
              >
                {gettext("Remove")}
              </.button>
            </li>
          </ul>

          <p :if={@credentials == []} class="text-base-content/50 text-sm" id="security-keys-empty">
            {gettext("No security keys yet.")}
          </p>

          <div id="webauthn-register" phx-hook="WebAuthn">
            <.button
              type="button"
              class="btn btn-primary btn-sm"
              id="add-security-key"
              phx-click="begin_add_key"
            >
              <.icon name="hero-plus" class="size-4" /> {gettext("Add security key")}
            </.button>
          </div>
        </section>

        <div :if={@totp_enabled?} class="divider" />

        <%!-- Recovery codes --%>
        <section
          :if={@totp_enabled?}
          aria-labelledby="recovery-heading"
          id="recovery-settings"
          class="space-y-3"
        >
          <h2 id="recovery-heading" class="font-semibold">{gettext("Recovery codes")}</h2>

          <div :if={@recovery_codes} id="recovery-codes-display" aria-live="polite">
            <p class="text-sm opacity-80">
              {gettext("Save these somewhere safe. Each works once. They won't be shown again.")}
            </p>
            <ul class="my-3 grid grid-cols-2 gap-2 font-mono text-sm">
              <li :for={code <- @recovery_codes} class="rounded bg-base-200 px-2 py-1 text-center">
                {code}
              </li>
            </ul>
          </div>

          <p :if={is_nil(@recovery_codes)} class="text-base-content/60 text-sm">
            {gettext("You have %{count} unused recovery codes.", count: @recovery_remaining)}
          </p>

          <.button
            type="button"
            class="btn btn-outline btn-sm"
            id="regenerate-recovery-codes"
            phx-click="regenerate_recovery_codes"
            data-confirm={
              gettext("Generate a new set? Your current recovery codes will stop working.")
            }
          >
            {gettext("Regenerate recovery codes")}
          </.button>
        </section>

        <div class="text-center">
          <.link
            navigate={~p"/users/settings"}
            id="back-to-settings"
            class="link link-primary text-sm"
          >
            {gettext("← Back to account settings")}
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, gettext("Two-factor authentication")) |> load_state()}
  end

  defp load_state(socket) do
    # Re-read the user from the DB so toggles (enable/disable TOTP) are reflected — the
    # scope captured at mount is otherwise stale after a mutation.
    user = Accounts.get_user!(socket.assigns.current_scope.user.id)

    socket
    |> assign(:current_scope, Scope.for_user(user))
    |> assign(:totp_enabled?, Accounts.totp_enabled?(user))
    |> assign(:credentials, Accounts.list_webauthn_credentials(user))
    |> assign(:recovery_remaining, Accounts.recovery_codes_remaining(user))
    |> assign_new(:totp_setup, fn -> nil end)
    |> assign_new(:recovery_codes, fn -> nil end)
    |> assign_new(:webauthn_challenge_token, fn -> nil end)
    |> assign_new(:totp_form, fn -> to_form(%{"totp_code" => ""}, as: "user") end)
  end

  # --- TOTP ---

  @impl true
  def handle_event("begin_totp_setup", _params, socket) do
    user = socket.assigns.current_scope.user
    secret = Accounts.generate_totp_secret()
    uri = Accounts.totp_uri(secret, user.email)

    setup = %{
      secret: secret,
      secret_base32: Base.encode32(secret, padding: false),
      qr_data_uri: Accounts.totp_qr_data_uri(uri)
    }

    {:noreply, assign(socket, totp_setup: setup, recovery_codes: nil)}
  end

  def handle_event("cancel_totp_setup", _params, socket) do
    {:noreply, assign(socket, :totp_setup, nil)}
  end

  def handle_event("enable_totp", %{"user" => %{"totp_code" => code}}, socket) do
    user = socket.assigns.current_scope.user
    secret = socket.assigns.totp_setup && socket.assigns.totp_setup.secret

    if secret && Accounts.valid_totp?(secret, code) do
      {:ok, _user} = Accounts.enable_totp(user, secret)
      codes = Accounts.generate_recovery_codes(user)

      {:noreply,
       socket
       |> assign(totp_setup: nil, recovery_codes: codes)
       |> put_flash(:info, gettext("Authenticator app turned on."))
       |> load_state()}
    else
      {:noreply, put_flash(socket, :error, gettext("That code is not valid. Please try again."))}
    end
  end

  def handle_event("disable_totp", _params, socket) do
    user = socket.assigns.current_scope.user

    if Accounts.can_remove_second_factor?(user, :totp) do
      {:ok, _user} = Accounts.disable_totp(user)

      {:noreply,
       socket
       |> assign(recovery_codes: nil)
       |> put_flash(:info, gettext("Authenticator app turned off."))
       |> load_state()}
    else
      {:noreply, put_flash(socket, :error, last_factor_message())}
    end
  end

  # --- Recovery codes ---

  def handle_event("regenerate_recovery_codes", _params, socket) do
    codes = Accounts.generate_recovery_codes(socket.assigns.current_scope.user)

    {:noreply,
     socket
     |> assign(:recovery_codes, codes)
     |> put_flash(:info, gettext("New recovery codes generated."))
     |> load_state()}
  end

  # --- Security keys ---

  def handle_event("begin_add_key", _params, socket) do
    {token, options} = Accounts.begin_webauthn_registration(socket.assigns.current_scope.user)

    {:noreply,
     socket
     |> assign(:webauthn_challenge_token, token)
     |> push_event("webauthn_register", %{options: options, callback: "webauthn_registered"})}
  end

  def handle_event("webauthn_registered", params, socket) do
    user = socket.assigns.current_scope.user
    token = socket.assigns.webauthn_challenge_token

    with {:ok, challenge} <- Goodmao2.Accounts.WebAuthnChallenges.pop(token, user.id),
         {:ok, attrs} <-
           Accounts.finish_webauthn_registration(
             user,
             params["attestation_object"],
             params["client_data_json"],
             challenge
           ),
         {:ok, _cred} <- Accounts.create_webauthn_credential(user, attrs) do
      {:noreply,
       socket
       |> assign(:webauthn_challenge_token, nil)
       |> put_flash(:info, gettext("Security key added."))
       |> load_state()}
    else
      _ ->
        {:noreply,
         socket
         |> assign(:webauthn_challenge_token, nil)
         |> put_flash(:error, gettext("Could not add that security key. Please try again."))}
    end
  end

  def handle_event("webauthn_error", %{"message" => message}, socket) do
    text =
      case message do
        "unsupported" -> gettext("This browser does not support security keys.")
        "NotAllowedError" -> gettext("The request was cancelled or timed out.")
        _ -> gettext("Something went wrong talking to your security key.")
      end

    {:noreply, put_flash(socket, :error, text)}
  end

  def handle_event("delete_key", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    if Accounts.can_remove_second_factor?(user, :webauthn) do
      case Accounts.delete_webauthn_credential(user, id) do
        {:ok, _} ->
          {:noreply, socket |> put_flash(:info, gettext("Security key removed.")) |> load_state()}

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, gettext("That security key was not found."))}
      end
    else
      {:noreply, put_flash(socket, :error, last_factor_message())}
    end
  end

  defp last_factor_message do
    gettext("You must keep at least one second factor. Add another before removing this one.")
  end
end
