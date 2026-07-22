defmodule Goodmao2Web.PetLive.EndOfCare do
  @moduledoc """
  Owner-only end-of-care page — a gentle, deliberate lifecycle transition kept off
  the daily view. Ending care is a status change, not a deletion: the record and
  its timeline are preserved. The end date is backdatable.
  """
  use Goodmao2Web, :live_view

  alias Goodmao2.Pets
  alias Goodmao2.Pets.Pet

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_scope.user

    case Pets.fetch_pet(user, id, require: :manage) do
      {:ok, pet} ->
        {:ok,
         socket
         |> assign(:page_title, gettext("End of care · %{name}", name: pet.name))
         |> assign(:pet, pet)
         |> assign_form(Pets.change_pet_lifecycle(pet))}

      {:error, :not_found} ->
        {:ok,
         socket |> put_flash(:error, gettext("Pet not found.")) |> push_navigate(to: ~p"/pets")}
    end
  end

  @impl true
  def handle_event("validate", %{"pet" => params}, socket) do
    changeset =
      Pets.change_pet_lifecycle(socket.assigns.pet, params) |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"pet" => params}, socket) do
    user = socket.assigns.current_scope.user

    case Pets.update_pet_lifecycle(user, socket.assigns.pet, params) do
      {:ok, pet} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Saved. %{name}'s record is preserved.", name: pet.name))
         |> push_navigate(to: ~p"/pets/#{pet.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, :unauthorized} ->
        {:noreply,
         socket |> put_flash(:error, gettext("Not allowed.")) |> push_navigate(to: ~p"/pets")}
    end
  end

  defp assign_form(socket, changeset), do: assign(socket, :form, to_form(changeset))

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
      <section id="eol-section" aria-labelledby="eol-heading" class="mx-auto max-w-lg">
        <div class="flex items-center gap-2">
          <.link
            navigate={~p"/pets/#{@pet.id}/edit"}
            id="eol-back"
            class="btn btn-ghost btn-sm btn-circle"
            aria-label={gettext("Back")}
          >
            <.icon name="hero-arrow-left" class="size-4" />
          </.link>
          <h1 id="eol-heading" class="text-2xl font-semibold">{gettext("End of care")}</h1>
        </div>

        <p class="text-base-content/70 mt-3 text-sm">
          {gettext(
            "This records that %{name} is no longer under your active care — for example if they have passed away, been rehomed, or been lost. Nothing is deleted: the full record and timeline are kept and stay reachable by direct link; %{name} simply leaves your active list. Hiding the history is a separate, reversible choice.",
            name: @pet.name
          )}
        </p>

        <.form
          for={@form}
          id="eol-form"
          phx-change="validate"
          phx-submit="save"
          class="mt-6 space-y-4"
        >
          <.input
            field={@form[:lifecycle_status]}
            type="select"
            label={gettext("Status")}
            options={Enum.map(Pet.lifecycle_statuses(), &{translate_lifecycle(&1), &1})}
          />
          <.input
            field={@form[:ended_at]}
            type="datetime-local"
            label={gettext("When care ended (optional — defaults to now)")}
          />

          <div class="flex items-center gap-3 pt-2">
            <.button
              type="submit"
              id="eol-submit"
              class="btn btn-primary"
              phx-disable-with={gettext("Saving…")}
            >
              {gettext("Save")}
            </.button>
            <.link navigate={~p"/pets/#{@pet.id}"} id="eol-cancel" class="btn btn-ghost">
              {gettext("Cancel")}
            </.link>
          </div>
        </.form>
      </section>
    </Layouts.app>
    """
  end
end
