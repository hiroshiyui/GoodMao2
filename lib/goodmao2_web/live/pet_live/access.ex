defmodule Goodmao2Web.PetLive.Access do
  @moduledoc """
  Owner-only sharing page: grant per-pet access by `@handle` or email, choose a
  role and optional expiry (time-boxed vet access), and revoke grants. The
  last-owner invariant is enforced by the `Pets` context.
  """
  use Goodmao2Web, :live_view

  alias Goodmao2.Pets
  alias Goodmao2.Pets.PetAccess

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_scope.user

    case Pets.fetch_pet(user, id, require: :manage) do
      {:ok, pet} ->
        {:ok,
         socket
         |> assign(:page_title, gettext("Sharing %{name}", name: pet.name))
         |> assign(:pet, pet)
         |> assign(:grant_form, to_form(%{"role" => "co_caretaker"}, as: :grant))
         |> load_accesses()}

      {:error, :not_found} ->
        {:ok,
         socket |> put_flash(:error, gettext("Pet not found.")) |> push_navigate(to: ~p"/pets")}
    end
  end

  defp load_accesses(socket) do
    stream(socket, :accesses, Pets.list_accesses(socket.assigns.pet), reset: true)
  end

  @impl true
  def handle_event("grant", %{"grant" => params}, socket) do
    user = socket.assigns.current_scope.user

    case Pets.grant_access(user, socket.assigns.pet, params) do
      {:ok, _access} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Access granted."))
         |> assign(:grant_form, to_form(%{"role" => "co_caretaker"}, as: :grant))
         |> load_accesses()}

      {:error, :grantee_not_found} ->
        {:noreply, put_flash(socket, :error, gettext("No account matches that handle or email."))}

      {:error, :vet_not_verified} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Only a verified veterinarian can be given the vet role.")
         )}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to manage sharing."))}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Could not grant access. Check the details and try again.")
         )}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user
    access = Enum.find(Pets.list_accesses(socket.assigns.pet), &(to_string(&1.id) == id))

    cond do
      is_nil(access) ->
        {:noreply, put_flash(socket, :error, gettext("Grant not found."))}

      true ->
        case Pets.revoke_access(user, socket.assigns.pet, access) do
          {:ok, _} ->
            {:noreply, socket |> put_flash(:info, gettext("Access revoked.")) |> load_accesses()}

          {:error, :last_owner} ->
            {:noreply, put_flash(socket, :error, gettext("A pet must keep at least one owner."))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Could not revoke that grant."))}
        end
    end
  end

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
      <section id="access-section" aria-labelledby="access-heading" class="mx-auto max-w-xl">
        <div class="flex items-center gap-2">
          <.link
            navigate={~p"/pets/#{@pet.id}"}
            id="access-back"
            class="btn btn-ghost btn-sm btn-circle"
            aria-label={gettext("Back")}
          >
            <.icon name="hero-arrow-left" class="size-4" />
          </.link>
          <h1 id="access-heading" class="text-2xl font-semibold">
            {gettext("Sharing %{name}", name: @pet.name)}
          </h1>
        </div>

        <.form
          for={@grant_form}
          id="grant-form"
          phx-submit="grant"
          class="card card-border bg-base-100 mt-6"
        >
          <div class="card-body space-y-3 p-4">
            <h2 class="text-lg font-semibold">{gettext("Invite someone")}</h2>
            <.input
              field={@grant_form[:identifier]}
              type="text"
              label={gettext("@handle or email")}
              required
            />
            <div class="grid gap-3 sm:grid-cols-2">
              <.input
                field={@grant_form[:role]}
                type="select"
                label={gettext("Role")}
                options={Enum.map(PetAccess.roles(), &{translate_role(&1), &1})}
              />
              <.input
                field={@grant_form[:expires_at]}
                type="datetime-local"
                label={gettext("Access expires (optional)")}
              />
            </div>
            <p class="text-base-content/60 text-xs">
              {gettext(
                "Tip: give a veterinarian a time-boxed expiry so their access ends after the visit."
              )}
            </p>
            <.button type="submit" id="grant-submit" class="btn btn-primary w-fit">
              {gettext("Grant access")}
            </.button>
          </div>
        </.form>

        <h2 id="current-access-heading" class="mt-8 text-lg font-semibold">
          {gettext("People with access")}
        </h2>
        <ul id="accesses" phx-update="stream" class="mt-3 space-y-2">
          <li class="hidden only:block text-base-content/60 py-4 text-center" id="accesses-empty">
            {gettext("No one else has access yet.")}
          </li>
          <li
            :for={{dom_id, access} <- @streams.accesses}
            id={dom_id}
            class="access-row card card-border bg-base-100"
          >
            <div class="card-body flex-row items-center justify-between gap-3 p-3">
              <div class="min-w-0">
                <p class="access-row-user font-medium break-words">
                  {Layouts.account_label(access.user)}
                </p>
                <p class="access-row-meta text-base-content/60 text-sm">
                  {translate_role(access.role)}
                  <span :if={access.expires_at}>
                    · {gettext("until %{t}", t: format_datetime(access.expires_at))}
                  </span>
                </p>
              </div>
              <button
                type="button"
                id={"revoke-#{access.id}"}
                phx-click="revoke"
                phx-value-id={access.id}
                data-confirm={gettext("Revoke access for this person?")}
                class="access-row-revoke btn btn-ghost btn-sm"
              >
                {gettext("Revoke")}
              </button>
            </div>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end
end
