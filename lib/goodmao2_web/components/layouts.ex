defmodule Goodmao2Web.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use Goodmao2Web, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header id="site-header" class="navbar border-b border-base-200 px-4 sm:px-6 lg:px-8">
      <div class="flex-1">
        <.link
          navigate={~p"/"}
          id="site-brand"
          class="flex w-fit items-center gap-2 text-lg font-semibold"
        >
          <span aria-hidden="true">🐾</span>
          <span>GoodMao <span class="text-base-content/50 text-sm font-normal">顧毛</span></span>
        </.link>
      </div>
      <nav id="site-nav" aria-label={gettext("Primary")} class="flex-none">
        <ul class="flex items-center gap-2 sm:gap-3">
          <%= if @current_scope && @current_scope.user do %>
            <li>
              <.link navigate={~p"/pets"} id="nav-pets" class="btn btn-ghost btn-sm">
                {gettext("My pets")}
              </.link>
            </li>
            <%= if @current_scope.user.is_admin do %>
              <li>
                <span
                  id="nav-admin-badge"
                  class="badge badge-secondary badge-sm"
                  title={gettext("Administrator")}
                >
                  {gettext("Admin")}
                </span>
              </li>
            <% end %>
            <li>
              <.link navigate={~p"/users/settings"} id="nav-settings" class="btn btn-ghost btn-sm">
                {account_label(@current_scope.user)}
              </.link>
            </li>
            <li>
              <.link
                href={~p"/users/log-out"}
                method="delete"
                id="nav-logout"
                class="btn btn-ghost btn-sm"
              >
                {gettext("Log out")}
              </.link>
            </li>
          <% else %>
            <li>
              <.link navigate={~p"/users/log-in"} id="nav-login" class="btn btn-ghost btn-sm">
                {gettext("Log in")}
              </.link>
            </li>
            <li>
              <.link navigate={~p"/users/register"} id="nav-register" class="btn btn-primary btn-sm">
                {gettext("Get started")}
              </.link>
            </li>
          <% end %>
          <li>
            <.theme_toggle />
          </li>
        </ul>
      </nav>
    </header>

    <main class="px-4 py-8 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-3xl space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc "The label shown for the signed-in account: their @handle, display name, or email."
  def account_label(user) do
    cond do
      is_binary(user.handle) and user.handle != "" -> "@" <> user.handle
      is_binary(user.display_name) and user.display_name != "" -> user.display_name
      true -> user.email
    end
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
