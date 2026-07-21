defmodule Goodmao2Web.UserLive.Settings do
  use Goodmao2Web, :live_view

  on_mount {Goodmao2Web.UserAuth, :require_sudo_mode}

  alias Goodmao2.Accounts
  alias Goodmao2.Notifications.WebPush

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      unread_notifications={@unread_notifications}
      unread_messages={@unread_messages}
    >
      <div class="text-center">
        <.header>
          {gettext("Account settings")}
          <:subtitle>{gettext("Manage your profile and email address")}</:subtitle>
        </.header>
      </div>

      <.form
        for={@profile_form}
        id="profile_form"
        phx-submit="update_profile"
        phx-change="validate_profile"
      >
        <.input
          field={@profile_form[:display_name]}
          type="text"
          label={gettext("Display name")}
        />
        <.input
          field={@profile_form[:handle]}
          type="text"
          label={gettext("Public @handle")}
          placeholder="dr_lin"
          autocomplete="off"
          spellcheck="false"
        />
        <p class="text-base-content/60 text-xs">
          {gettext("Your handle lets others invite you to a pet by @handle.")}
        </p>
        <.button variant="primary" phx-disable-with={gettext("Saving...")}>
          {gettext("Save profile")}
        </.button>
      </.form>

      <div class="divider" />

      <.form for={@email_form} id="email_form" phx-submit="update_email" phx-change="validate_email">
        <.input
          field={@email_form[:email]}
          type="email"
          label={gettext("Email")}
          autocomplete="username"
          spellcheck="false"
          required
        />
        <.input
          field={@email_form[:current_password]}
          type="password"
          label={gettext("Current password")}
          value={@email_form_current_password}
          autocomplete="current-password"
          spellcheck="false"
          required
        />
        <.button variant="primary" phx-disable-with={gettext("Changing...")}>
          {gettext("Change Email")}
        </.button>
      </.form>

      <div class="divider" />

      <div id="password-settings-link" class="text-center">
        <p class="text-base-content/60 mb-2 text-sm">
          {gettext("Your password is managed on its own page.")}
        </p>
        <.link navigate={~p"/users/settings/password"} class="btn btn-soft btn-primary">
          {gettext("Change password")}
        </.link>
      </div>

      <div :if={@push_configured} class="divider" />

      <%!-- Web Push opt-in (ADR-0011 Stage 2). Only offered when the site has VAPID keys.
            The PushManager hook reports browser support + current subscription state, and the
            buttons dispatch DOM events it listens for (CSP-safe — no inline handlers). --%>
      <section
        :if={@push_configured}
        id="push-manager"
        phx-hook="PushManager"
        aria-labelledby="push-heading"
        class="text-center"
      >
        <h2 id="push-heading" class="font-semibold">{gettext("Push notifications")}</h2>
        <p class="text-base-content/60 mt-1 mb-2 text-sm" aria-live="polite">
          <%= cond do %>
            <% not @push_supported -> %>
              {gettext("This browser doesn't support push notifications.")}
            <% @push_subscribed -> %>
              {gettext("Push notifications are on for this device.")}
            <% true -> %>
              {gettext(
                "Get notified about access changes, new logs, and announcements even when GoodMao is closed."
              )}
          <% end %>
        </p>
        <button
          :if={@push_supported and not @push_subscribed}
          type="button"
          id="push-enable"
          phx-click={JS.dispatch("push:subscribe", to: "#push-manager")}
          class="btn btn-soft btn-primary"
        >
          {gettext("Enable push")}
        </button>
        <button
          :if={@push_supported and @push_subscribed}
          type="button"
          id="push-disable"
          phx-click={JS.dispatch("push:unsubscribe", to: "#push-manager")}
          class="btn btn-soft"
        >
          {gettext("Disable push")}
        </button>
      </section>

      <div class="divider" />

      <div id="vet-profile-link" class="text-center">
        <p class="text-base-content/60 mb-2 text-sm">
          {gettext("Are you a veterinarian? Submit your credentials to be verified.")}
        </p>
        <.link navigate={~p"/users/vet-profile"} class="btn btn-soft">
          {gettext("Veterinarian credentials")}
        </.link>
      </div>

      <%!-- A subtle, memorial entry to the "past pets" surface (ADR-0003): companions
            whose care has ended are preserved and reachable, just kept off the active
            list rather than shown beside the living. --%>
      <div id="past-pets-link" class="mt-8 text-center">
        <.link
          navigate={~p"/pets/past"}
          class="text-base-content/50 hover:text-base-content/70 inline-flex items-center gap-1 text-sm"
        >
          <.icon name="hero-heart" class="size-4" /> {gettext("Past pets")}
        </.link>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, gettext("Email changed successfully."))

        {:error, _} ->
          put_flash(socket, :error, gettext("Email change link is invalid or it has expired."))
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    profile_changeset = Accounts.change_user_profile(user, %{}, validate_unique: false)

    socket =
      socket
      |> assign(:page_title, gettext("Account settings"))
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:email_form_current_password, nil)
      |> assign(:profile_form, to_form(profile_changeset))
      |> assign(:push_configured, WebPush.vapid_configured?())
      |> assign(:push_supported, false)
      |> assign(:push_subscribed, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_profile", %{"user" => user_params}, socket) do
    profile_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_profile(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, profile_form: profile_form)}
  end

  def handle_event("update_profile", %{"user" => user_params}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.update_user_profile(user, user_params) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Profile updated."))
         |> assign(:profile_form, to_form(Accounts.change_user_profile(updated)))}

      {:error, changeset} ->
        {:noreply, assign(socket, :profile_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    # The current-password error is held back until submit (like the password page), so
    # it doesn't flash while the user is still typing the new email.
    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply,
     assign(socket,
       email_form: email_form,
       email_form_current_password: user_params["current_password"]
     )}
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params
    current_password = user_params["current_password"]
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_email(user, user_params, current_password: current_password) do
      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        info =
          gettext("A link to confirm your email change has been sent to the new address.")

        {:noreply, socket |> put_flash(:info, info) |> assign(email_form_current_password: nil)}

      changeset ->
        {:noreply,
         socket
         |> assign(:email_form, to_form(changeset, action: :insert))
         |> assign(:email_form_current_password, current_password)}
    end
  end

  ## Web Push (ADR-0011 Stage 2) — events pushed up by the PushManager JS hook.

  def handle_event(
        "push_support",
        %{"supported" => supported, "subscribed" => subscribed},
        socket
      ) do
    {:noreply, assign(socket, push_supported: supported, push_subscribed: subscribed)}
  end

  def handle_event("push_subscribed", _params, socket) do
    {:noreply,
     socket
     |> assign(:push_subscribed, true)
     |> put_flash(:info, gettext("Push notifications enabled for this device."))}
  end

  def handle_event("push_unsubscribed", _params, socket) do
    {:noreply,
     socket
     |> assign(:push_subscribed, false)
     |> put_flash(:info, gettext("Push notifications disabled for this device."))}
  end

  def handle_event("push_permission_denied", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("Notification permission was denied."))}
  end

  def handle_event("push_subscribe_error", _params, socket) do
    {:noreply,
     put_flash(socket, :error, gettext("Couldn't update push notifications. Please try again."))}
  end

  # (Password change moved to Goodmao2Web.UserLive.PasswordSettings — gated by the
  # current password in addition to sudo mode.)
end
