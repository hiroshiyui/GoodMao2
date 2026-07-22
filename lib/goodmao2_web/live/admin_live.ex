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
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      unread_notifications={@unread_notifications}
      unread_messages={@unread_messages}
      current_user_avatar={@current_user_avatar}
    >
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

      <div class="mt-4 flex flex-wrap gap-2">
        <.link navigate={~p"/admin/announcements"} id="admin-announcements-link" class="btn btn-sm">
          <.icon name="hero-megaphone" class="size-4" /> {gettext("Post an announcement")}
        </.link>
        <.link navigate={~p"/admin/settings"} id="admin-settings-link" class="btn btn-sm">
          <.icon name="hero-cog-6-tooth" class="size-4" /> {gettext("System settings")}
        </.link>
      </div>

      <section id="vet-verifications" aria-labelledby="vet-verifications-heading" class="mt-10">
        <h2 id="vet-verifications-heading" class="text-lg font-semibold">
          {gettext("Veterinarian verifications")}
        </h2>
        <p class="text-base-content/60 mt-1 text-sm">
          {gettext("Review submitted credentials before the vet role can be granted anywhere.")}
        </p>

        <ul id="pending-vet-profiles" class="mt-3 space-y-2">
          <li
            :if={@pending_vets == []}
            id="pending-vet-profiles-empty"
            class="text-base-content/60 py-4 text-center"
          >
            {gettext("No credentials are awaiting review.")}
          </li>
          <li
            :for={profile <- @pending_vets}
            id={"vet-profile-#{profile.id}"}
            class="vet-profile-row card card-border bg-base-100"
          >
            <div class="card-body gap-3 p-4">
              <div>
                <p class="vet-profile-user font-medium break-words">
                  {Layouts.account_label(profile.user)}
                </p>
                <dl class="text-base-content/70 mt-1 grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-sm">
                  <dt>{gettext("License")}</dt>
                  <dd class="break-words">{profile.license_number}</dd>
                  <dt>{gettext("Licensing body")}</dt>
                  <dd class="break-words">{profile.licensing_body}</dd>
                  <dt>{gettext("Region")}</dt>
                  <dd class="break-words">{profile.region}</dd>
                  <dt>{gettext("Clinic")}</dt>
                  <dd class="break-words">{profile.clinic_name}</dd>
                  <dt :if={profile.specialty}>{gettext("Specialty")}</dt>
                  <dd :if={profile.specialty} class="break-words">{profile.specialty}</dd>
                </dl>
              </div>
              <div class="flex gap-2">
                <button
                  type="button"
                  id={"verify-#{profile.id}"}
                  phx-click="verify"
                  phx-value-id={profile.id}
                  class="btn btn-primary btn-sm"
                >
                  {gettext("Verify")}
                </button>
                <button
                  type="button"
                  id={"reject-#{profile.id}"}
                  phx-click="reject"
                  phx-value-id={profile.id}
                  data-confirm={gettext("Reject these credentials?")}
                  class="btn btn-ghost btn-sm"
                >
                  {gettext("Reject")}
                </button>
              </div>
            </div>
          </li>
        </ul>
      </section>
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
      |> load_pending_vets()

    {:ok, socket}
  end

  @impl true
  def handle_event("verify", %{"id" => id}, socket) do
    review(socket, id, &Accounts.verify_vet_profile/2, gettext("Veterinarian verified."))
  end

  def handle_event("reject", %{"id" => id}, socket) do
    review(socket, id, &Accounts.reject_vet_profile/2, gettext("Credentials rejected."))
  end

  defp review(socket, id, fun, ok_message) do
    admin = socket.assigns.current_scope.user
    profile = Enum.find(socket.assigns.pending_vets, &(to_string(&1.id) == id))

    cond do
      is_nil(profile) ->
        {:noreply, put_flash(socket, :error, gettext("That submission is no longer pending."))}

      true ->
        case fun.(admin, profile) do
          {:ok, _} ->
            {:noreply, socket |> put_flash(:info, ok_message) |> load_pending_vets()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Could not update that submission."))}
        end
    end
  end

  defp load_pending_vets(socket),
    do: assign(socket, :pending_vets, Accounts.list_pending_vet_profiles())
end
