defmodule Goodmao2Web.PetLive.Form do
  @moduledoc """
  Create or edit a pet's descriptive attributes. Editing requires the `:manage`
  capability (owner). Lifecycle end-of-care lives on its own page, never here.
  """
  use Goodmao2Web, :live_view

  alias Goodmao2.Pets
  alias Goodmao2.Pets.Pet

  @impl true
  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    changeset = Pets.change_pet(%Pet{})

    socket
    |> assign(:page_title, gettext("Add a pet"))
    |> assign(:pet, %Pet{})
    |> assign_form(changeset)
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    user = socket.assigns.current_scope.user

    case Pets.fetch_pet(user, id, require: :manage) do
      {:ok, pet} ->
        socket
        |> assign(:page_title, gettext("Edit %{name}", name: pet.name))
        |> assign(:pet, pet)
        |> assign_form(Pets.change_pet(pet))

      {:error, :not_found} ->
        socket
        |> put_flash(:error, gettext("Pet not found."))
        |> push_navigate(to: ~p"/pets")
    end
  end

  @impl true
  def handle_event("validate", %{"pet" => params}, socket) do
    changeset = Pets.change_pet(socket.assigns.pet, params) |> Map.put(:action, :validate)
    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"pet" => params}, socket) do
    save_pet(socket, socket.assigns.live_action, params)
  end

  defp save_pet(socket, :new, params) do
    user = socket.assigns.current_scope.user

    case Pets.create_pet(user, params) do
      {:ok, pet} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{name} added.", name: pet.name))
         |> push_navigate(to: ~p"/pets/#{pet.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_pet(socket, :edit, params) do
    user = socket.assigns.current_scope.user

    case Pets.update_pet(user, socket.assigns.pet, params) do
      {:ok, pet} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Saved."))
         |> push_navigate(to: ~p"/pets/#{pet.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, :unauthorized} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not allowed to edit this pet."))
         |> push_navigate(to: ~p"/pets")}
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
    >
      <section id="pet-form-section" aria-labelledby="pet-form-heading" class="mx-auto max-w-xl">
        <h1 id="pet-form-heading" class="text-2xl font-semibold">{@page_title}</h1>

        <.form
          for={@form}
          id="pet-form"
          phx-change="validate"
          phx-submit="save"
          class="mt-6 space-y-4"
        >
          <.input field={@form[:name]} type="text" label={gettext("Name")} required />

          <div class="grid gap-4 sm:grid-cols-2">
            <.input
              field={@form[:species]}
              type="select"
              label={gettext("Species")}
              options={Enum.map(Pet.species(), &{translate_species(&1), &1})}
            />
            <.input
              field={@form[:sex]}
              type="select"
              label={gettext("Sex")}
              options={Enum.map(Pet.sexes(), &{translate_sex(&1), &1})}
            />
          </div>

          <div class="grid gap-4 sm:grid-cols-2">
            <.input field={@form[:breed]} type="text" label={gettext("Breed")} />
            <.input field={@form[:color]} type="text" label={gettext("Coat colour")} />
          </div>

          <div class="grid gap-4 sm:grid-cols-2">
            <.input field={@form[:birth_date]} type="date" label={gettext("Birth date")} />
            <.input
              field={@form[:weight_unit]}
              type="select"
              label={gettext("Weight unit")}
              options={Enum.map(Pet.weight_units(), &{translate_weight_unit(&1), &1})}
            />
          </div>

          <.input field={@form[:neutered]} type="checkbox" label={gettext("Neutered / spayed")} />

          <div class="flex items-center gap-3 pt-2">
            <.button
              type="submit"
              id="pet-form-submit"
              class="btn btn-primary"
              phx-disable-with={gettext("Saving…")}
            >
              {gettext("Save")}
            </.button>
            <.link
              navigate={if @pet.id, do: ~p"/pets/#{@pet.id}", else: ~p"/pets"}
              id="pet-form-cancel"
              class="btn btn-ghost"
            >
              {gettext("Cancel")}
            </.link>
          </div>
        </.form>

        <div :if={@live_action == :edit} id="pet-eol" class="mt-10 border-t border-base-200 pt-4">
          <.link
            navigate={~p"/pets/#{@pet.id}/end-of-care"}
            id="pet-eol-link"
            class="text-base-content/60 text-sm hover:underline"
          >
            {gettext("End of care for %{name}…", name: @pet.name)}
          </.link>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
