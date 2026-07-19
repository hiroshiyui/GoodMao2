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
          <%!-- Mobile: everything collapses into a hamburger disclosure (CSP-safe, no JS). --%>
          <details id="nav-menu" class="dropdown dropdown-end lg:hidden">
            <summary id="nav-menu-toggle" class="btn btn-ghost btn-sm" aria-label={gettext("Menu")}>
              <.icon name="hero-bars-3" class="size-5" />
            </summary>
            <div class="dropdown-content z-40 mt-2 w-56 rounded-box border border-base-200 bg-base-100 p-2 shadow">
              <ul class="menu w-full gap-1">
                <.nav_links current_scope={@current_scope} id_prefix="m-" />
              </ul>
              <div class="mt-2 flex items-center justify-between gap-2 border-t border-base-200 px-1 pt-3">
                <.font_size_controls id_prefix="m-" />
                <.theme_toggle />
              </div>
            </div>
          </details>

          <%!-- Desktop: the full inline bar (canonical, test-anchored ids). --%>
          <ul class="hidden items-center gap-2 sm:gap-3 lg:flex">
            <.nav_links current_scope={@current_scope} />
            <li>
              <.font_size_controls />
            </li>
            <li>
              <.theme_toggle />
            </li>
          </ul>
        </nav>
      </header>

      <main id="main-content" tabindex="-1" class="flex-1 px-4 py-8 sm:px-6 lg:px-8">
        <div class="mx-auto max-w-4xl space-y-4">
          {render_slot(@inner_block)}
        </div>
      </main>

      <footer id="site-footer" class="border-t border-base-200 px-4 py-6 sm:px-6 lg:px-8">
        <div class="mx-auto flex max-w-4xl flex-col items-center gap-2 text-center text-sm text-base-content/60">
          <p>
            <span aria-hidden="true">🐾</span>
            {gettext("GoodMao — a shareable health timeline for the pets you love.")}
          </p>
          <p>© {brand_name()}</p>
          <.locale_switcher
            locale={Gettext.get_locale(Goodmao2Web.Gettext)}
            class="dropdown-top dropdown-end"
          />
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

  # The primary navigation links (and the admin badge), rendered as `<li>` items. Shared by
  # the desktop inline bar and the mobile hamburger menu, so `id_prefix` keeps their element
  # ids unique across the two copies (the desktop copy keeps the canonical, test-anchored ids).
  attr :current_scope, :map, default: nil
  attr :id_prefix, :string, default: ""

  defp nav_links(assigns) do
    ~H"""
    <%= if @current_scope && @current_scope.user do %>
      <li>
        <.link navigate={~p"/pets"} id={"#{@id_prefix}nav-pets"} class="btn btn-ghost btn-sm">
          {gettext("My pets")}
        </.link>
      </li>
      <%= if @current_scope.user.is_admin do %>
        <li class="flex items-center">
          <.link
            navigate={~p"/admin"}
            id={"#{@id_prefix}nav-admin-badge"}
            class="badge badge-secondary badge-sm gap-1"
            title={gettext("Administration")}
          >
            <.icon name="hero-shield-check" class="size-3" /> {gettext("Admin")}
          </.link>
        </li>
      <% end %>
      <li>
        <.link
          navigate={~p"/users/settings"}
          id={"#{@id_prefix}nav-settings"}
          class="btn btn-ghost btn-sm"
        >
          {account_label(@current_scope.user)}
        </.link>
      </li>
      <li>
        <.link
          href={~p"/users/log-out"}
          method="delete"
          id={"#{@id_prefix}nav-logout"}
          class="btn btn-ghost btn-sm"
        >
          {gettext("Log out")}
        </.link>
      </li>
    <% else %>
      <li>
        <.link navigate={~p"/users/log-in"} id={"#{@id_prefix}nav-login"} class="btn btn-ghost btn-sm">
          {gettext("Log in")}
        </.link>
      </li>
      <li>
        <.link
          navigate={~p"/users/register"}
          id={"#{@id_prefix}nav-register"}
          class="btn btn-primary btn-sm"
        >
          {gettext("Get started")}
        </.link>
      </li>
    <% end %>
    """
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

  attr :class, :string,
    default: "dropdown-end",
    doc: "extra classes on the dropdown (e.g. `dropdown-top` to open upward from the footer)"

  def locale_switcher(assigns) do
    ~H"""
    <details class={["dropdown", @class]} id="locale-switcher">
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
  Renders font-size zoom in/out controls.

  Dispatches `phx:font-size-decrease` / `phx:font-size-increase`, handled by JS in
  `app.js`, which clamps and persists the root font-size in localStorage. See the
  pre-paint guard in root.html.heex which applies a stored size before first paint.
  """
  attr :id_prefix, :string,
    default: "",
    doc: "prefix for element ids so the control can render twice (desktop + mobile menu)"

  def font_size_controls(assigns) do
    ~H"""
    <div
      id={"#{@id_prefix}font-size-controls"}
      role="group"
      aria-label={gettext("Text size")}
      class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full"
    >
      <button
        id={"#{@id_prefix}font-size-decrease"}
        class="flex p-2 cursor-pointer"
        phx-click={JS.dispatch("phx:font-size-decrease")}
        aria-label={gettext("Decrease text size")}
        title={gettext("Decrease text size")}
      >
        <.icon name="hero-minus-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        id={"#{@id_prefix}font-size-increase"}
        class="flex p-2 cursor-pointer"
        phx-click={JS.dispatch("phx:font-size-increase")}
        aria-label={gettext("Increase text size")}
        title={gettext("Increase text size")}
      >
        <.icon name="hero-plus-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
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
