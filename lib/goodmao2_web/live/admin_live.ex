defmodule Goodmao2Web.AdminLive do
  @moduledoc """
  The administrator's site-overview page.

  A read-only oversight surface for the sole global administrator (`is_admin`) — the
  registered-user count, the administrator's own identity, and the first-registration
  gate status. Gated by `:require_admin`, which silently sends non-admins home. This is
  the seam future admin features (announcements, moderation) attach to.
  """
  use Goodmao2Web, :live_view

  on_mount {Goodmao2Web.UserAuth, :require_admin}

  alias Goodmao2.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        {gettext("Administration")}
        <:subtitle>{gettext("Platform overview and site status.")}</:subtitle>
      </.header>

      <dl id="admin-overview" class="divide-base-200 divide-y rounded-box border border-base-200">
        <div class="flex items-center justify-between gap-4 px-4 py-3">
          <dt class="text-base-content/70">{gettext("Administrator")}</dt>
          <dd id="admin-identity" class="font-medium">
            {Layouts.account_label(@current_scope.user)}
          </dd>
        </div>

        <div class="flex items-center justify-between gap-4 px-4 py-3">
          <dt class="text-base-content/70">{gettext("Registered users")}</dt>
          <dd id="admin-user-count" class="font-medium tabular-nums">{@user_count}</dd>
        </div>

        <div class="flex items-center justify-between gap-4 px-4 py-3">
          <dt class="text-base-content/70">{gettext("Registration")}</dt>
          <dd id="admin-registration-gate" class="text-right font-medium">
            <%= if @site_owner_email do %>
              <span class="badge badge-success badge-sm">{gettext("Restricted")}</span>
              <p class="text-base-content/60 mt-1 text-xs font-normal">
                {gettext("Only %{email} may create the first account.", email: @site_owner_email)}
              </p>
            <% else %>
              <span class="badge badge-warning badge-sm">{gettext("Open")}</span>
              <p class="text-base-content/60 mt-1 text-xs font-normal">
                {gettext("The first account to register becomes the administrator.")}
              </p>
            <% end %>
          </dd>
        </div>
      </dl>

      <p class="text-base-content/60 text-sm">
        {gettext("Administration is a global role. It grants no access to any pet's data.")}
      </p>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, gettext("Administration"))
      |> assign(:user_count, Accounts.count_users())
      |> assign(:site_owner_email, Accounts.site_owner_email())

    {:ok, socket}
  end
end
