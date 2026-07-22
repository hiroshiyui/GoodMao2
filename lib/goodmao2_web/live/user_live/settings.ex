defmodule Goodmao2Web.UserLive.Settings do
  use Goodmao2Web, :live_view

  on_mount {Goodmao2Web.UserAuth, :require_sudo_mode}

  alias Goodmao2.Accounts
  alias Goodmao2.Media
  alias Goodmao2.Media.Avatars
  alias Goodmao2.Notifications.WebPush

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      unread_notifications={@unread_notifications}
      unread_messages={@unread_messages}
      current_user_avatar={@current_user_avatar}
    >
      <div class="text-center">
        <.header>
          {gettext("Account settings")}
          <:subtitle>{gettext("Manage your profile and email address")}</:subtitle>
        </.header>
      </div>

      <section id="avatar-settings" aria-labelledby="avatar-heading" class="text-center">
        <h2 id="avatar-heading" class="sr-only">{gettext("Profile photo")}</h2>
        <div class="relative inline-flex flex-col items-center gap-1">
          <%!-- The avatar is a click-to-open trigger for the uploader popover. The open state is
                a server assign (not a native <details>) so it survives the re-render a file
                selection triggers. Click the avatar to toggle. --%>
          <button
            type="button"
            id="user-avatar-trigger"
            phx-click="toggle_avatar_menu"
            aria-expanded={to_string(@avatar_menu_open)}
            aria-haspopup="dialog"
            aria-controls="avatar_form"
            title={gettext("Change profile photo")}
            aria-label={gettext("Change profile photo")}
            class="cursor-pointer rounded-full focus-visible:outline-none"
          >
            <.avatar
              owner_type="user"
              owner_id={@current_scope.user.id}
              name={@current_scope.user.display_name}
              meta={@avatar_meta}
              size={:xl}
            />
          </button>

          <.form
            :if={@avatar_menu_open}
            for={%{}}
            id="avatar_form"
            phx-submit="save_avatar"
            phx-change="validate_avatar"
            class="absolute top-full z-40 mt-2 flex w-72 flex-col gap-2 rounded-box border border-base-200 bg-base-100 p-3 text-left shadow"
          >
            <label for={@uploads.avatar.ref} class="sr-only">
              {gettext("Choose a profile photo")}
            </label>
            <.live_file_input upload={@uploads.avatar} class="file-input file-input-sm w-full" />
            <.avatar_cropper id="user-avatar-cropper" />
            <div class="flex gap-2">
              <.button variant="primary" phx-disable-with={gettext("Uploading...")}>
                {gettext("Upload photo")}
              </.button>
              <.button
                :if={@avatar_meta}
                type="button"
                phx-click="remove_avatar"
                data-confirm={gettext("Remove your profile photo?")}
              >
                {gettext("Remove")}
              </.button>
            </div>
          </.form>

          <p :if={@avatar_meta[:status] == "processing"} class="text-base-content/60 text-xs">
            {gettext("Your photo is being processed…")}
          </p>
        </div>
      </section>

      <div class="divider" />

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
        <.input
          field={@profile_form[:timezone]}
          type="select"
          id="user-timezone-select"
          label={gettext("Timezone")}
          prompt={gettext("Use the site default")}
          options={Goodmao2.Timezone.all()}
          phx-hook="TimezoneDetect"
        />
        <p class="text-base-content/60 text-xs">
          {gettext(
            "Times you log and view are shown in this zone. Left blank, the site default is used."
          )}
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

      <div class="divider" />

      <div id="two-factor-settings-link" class="text-center">
        <p class="text-base-content/60 mb-2 text-sm">
          {gettext("Add a second step at sign-in with an authenticator app or a security key.")}
        </p>
        <.link navigate={~p"/users/settings/two-factor"} class="btn btn-soft btn-primary">
          {gettext("Two-factor authentication")}
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

    # The nav's UnreadBadges on_mount already subscribes this process to the user's avatar topic
    # and passes `{:avatar_updated, "user", …}` through, so our handle_info below reacts too.
    socket =
      socket
      |> assign(:page_title, gettext("Account settings"))
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:email_form_current_password, nil)
      |> assign(:profile_form, to_form(profile_changeset))
      |> assign(:avatar_meta, Avatars.meta("user", user.id))
      |> assign(:avatar_menu_open, false)
      |> assign(:push_configured, WebPush.vapid_configured?())
      |> assign(:push_supported, false)
      |> assign(:push_subscribed, false)
      |> allow_upload(:avatar,
        accept: ~w(.jpg .jpeg .png .webp .gif),
        max_entries: 1,
        max_file_size: Media.Limits.get(:max_image_bytes)
      )

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

  ## Profile photo (ADR-0020) — staged then purified async; the row broadcasts when ready.

  # The uploader popover's open state is server-owned so it survives the re-render a file
  # selection triggers (a native <details> would snap shut). Click the avatar to toggle.
  def handle_event("toggle_avatar_menu", _params, socket) do
    {:noreply, update(socket, :avatar_menu_open, &(not &1))}
  end

  def handle_event("validate_avatar", _params, socket), do: {:noreply, socket}

  def handle_event("save_avatar", params, socket) do
    user = socket.assigns.current_scope.user

    staged =
      consume_uploaded_entries(socket, :avatar, fn %{path: path}, _entry ->
        {:ok, Media.stage_upload(path)}
      end)

    case staged do
      [{:ok, token}] ->
        case Avatars.set_avatar("user", user.id, user, token, params["crop"]) do
          {:ok, avatar} ->
            {:noreply,
             socket
             |> assign(:avatar_meta, %{status: avatar.status, version: Avatars.version(avatar)})
             |> assign(:avatar_menu_open, false)
             |> put_flash(:info, gettext("Photo uploaded — it will appear once processed."))}

          {:error, _} ->
            Media.unstage_upload(token)
            {:noreply, put_flash(socket, :error, gettext("Couldn't upload your photo."))}
        end

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Please choose an image to upload."))}
    end
  end

  def handle_event("remove_avatar", _params, socket) do
    user = socket.assigns.current_scope.user
    :ok = Avatars.delete_avatar("user", user.id, user)

    {:noreply,
     socket
     |> assign(:avatar_meta, nil)
     |> assign(:avatar_menu_open, false)
     |> put_flash(:info, gettext("Profile photo removed."))}
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

  @impl true
  def handle_info({:avatar_updated, "user", _id, meta}, socket) do
    # `mark_failed`/`delete` broadcast a non-ready meta; treat a dropped row as "no avatar".
    meta = if meta.status == "ready", do: meta, else: nil
    {:noreply, assign(socket, :avatar_meta, meta)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # (Password change moved to Goodmao2Web.UserLive.PasswordSettings — gated by the
  # current password in addition to sudo mode.)
end
