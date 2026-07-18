defmodule Goodmao2Web.UserLive.PasswordSettings do
  @moduledoc """
  Isolated change-password page.

  Kept separate from the main account settings on purpose: changing the password is a
  high-value action, so it lives behind sudo mode (recent authentication) **and** a
  current-password check verified server-side. Submitting hands off to
  `UserSessionController.update_password/2` (via `phx-trigger-action`), which re-verifies
  the current password and re-establishes the session after the token rotation.
  """
  use Goodmao2Web, :live_view

  on_mount {Goodmao2Web.UserAuth, :require_sudo_mode}

  alias Goodmao2.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="text-center">
        <.header>
          {gettext("Change password")}
          <:subtitle>{gettext("Confirm your current password to set a new one.")}</:subtitle>
        </.header>
      </div>

      <.form
        for={@password_form}
        id="password_form"
        action={~p"/users/update-password"}
        method="post"
        phx-change="validate_password"
        phx-submit="update_password"
        phx-trigger-action={@trigger_submit}
      >
        <input
          name={@password_form[:email].name}
          type="hidden"
          id="hidden_user_email"
          autocomplete="username"
          value={@current_email}
        />
        <.input
          field={@password_form[:current_password]}
          type="password"
          label={gettext("Current password")}
          autocomplete="current-password"
          spellcheck="false"
          required
        />
        <.input
          field={@password_form[:password]}
          type="password"
          label={gettext("New password")}
          autocomplete="new-password"
          spellcheck="false"
          required
        />
        <.input
          field={@password_form[:password_confirmation]}
          type="password"
          label={gettext("Confirm new password")}
          autocomplete="new-password"
          spellcheck="false"
        />
        <.button variant="primary" phx-disable-with={gettext("Saving...")}>
          {gettext("Save password")}
        </.button>
      </.form>

      <div class="mt-4 text-center">
        <.link navigate={~p"/users/settings"} id="back-to-settings" class="link link-primary text-sm">
          {gettext("← Back to account settings")}
        </.link>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_password", %{"user" => user_params}, socket) do
    # On change we validate only the new password — the current-password error is held
    # back until submit, so it doesn't flash while the user is still typing.
    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", %{"user" => user_params}, socket) do
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    changeset =
      user
      |> Accounts.change_user_password(user_params,
        hash_password: false,
        current_password: user_params["current_password"]
      )
      |> Map.put(:action, :validate)

    if changeset.valid? do
      # Hand off to the controller (via phx-trigger-action) to do the actual mutation
      # and re-establish the session; the controller re-verifies the current password.
      {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}
    else
      {:noreply, assign(socket, password_form: to_form(changeset))}
    end
  end
end
