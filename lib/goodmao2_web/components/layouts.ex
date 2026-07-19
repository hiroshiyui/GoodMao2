defmodule Goodmao2Web.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use Goodmao2Web, :html

  alias Goodmao2Web.Locale

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
    <a
      href="#main-content"
      id="skip-to-content"
      class="gm-skip-link btn btn-primary btn-sm sr-only focus:not-sr-only"
    >
      {gettext("Skip to content")}
    </a>
    <div id="app-shell" class="flex min-h-dvh flex-col">
      <header
        id="site-header"
        class="navbar sticky top-0 z-30 border-b border-base-200 bg-base-100/90 px-4 backdrop-blur sm:px-6 lg:px-8"
      >
        <div class="flex-1">
          <.link
            navigate={~p"/"}
            id="site-brand"
            class="flex w-fit items-center gap-2 text-lg font-semibold"
          >
            <span aria-hidden="true">🐾</span>
            <span class="gm-brand">{brand_name()}</span>
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
                <li class="flex items-center">
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
              <.locale_switcher locale={Gettext.get_locale(Goodmao2Web.Gettext)} />
            </li>
            <li>
              <.theme_toggle />
            </li>
          </ul>
        </nav>
      </header>

      <main id="main-content" tabindex="-1" class="flex-1 px-4 py-8 sm:px-6 lg:px-8">
        <div class="mx-auto max-w-3xl space-y-4">
          {render_slot(@inner_block)}
        </div>
      </main>

      <footer id="site-footer" class="border-t border-base-200 px-4 py-6 sm:px-6 lg:px-8">
        <div class="mx-auto flex max-w-3xl flex-col items-center gap-1 text-center text-sm text-base-content/60">
          <p>
            <span aria-hidden="true">🐾</span>
            {gettext("GoodMao — a shareable health timeline for the pets you love.")}
          </p>
          <p>© {brand_name()}</p>
        </div>
      </footer>
    </div>

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
  Language switcher. Each locale is labelled with its own autonym (ADR-0002) so it is
  recognisable whatever the active UI language is. Switching is a plain GET navigation to
  `LocaleController`, which persists the choice in the `locale` cookie and reloads — no
  inline JS, so it stays within the Content-Security-Policy.
  """
  attr :locale, :string, required: true

  def locale_switcher(assigns) do
    ~H"""
    <details class="dropdown dropdown-end" id="locale-switcher">
      <summary class="btn btn-ghost btn-sm" aria-label={gettext("Change language")}>
        <.icon name="hero-language" class="size-4" />
        <span class="hidden sm:inline">{Locale.label(@locale)}</span>
      </summary>
      <ul class="menu dropdown-content z-40 mt-2 w-40 rounded-box border border-base-200 bg-base-100 p-2 shadow">
        <li :for={code <- Locale.known()}>
          <.link
            href={~p"/locale/#{code}"}
            id={"locale-option-#{code}"}
            class={code == @locale && "menu-active font-semibold"}
            aria-current={(code == @locale && "true") || nil}
          >
            {Locale.label(code)}
          </.link>
        </li>
      </ul>
    </details>
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
        aria-label={gettext("Match system theme")}
        title={gettext("Match system theme")}
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label={gettext("Light theme")}
        title={gettext("Light theme")}
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label={gettext("Dark theme")}
        title={gettext("Dark theme")}
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
