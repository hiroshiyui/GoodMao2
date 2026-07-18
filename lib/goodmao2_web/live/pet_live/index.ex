defmodule Goodmao2Web.PetLive.Index do
  @moduledoc """
  Lists the pets the current user can access. Active pets are the everyday surface at
  `/pets`; ended ("past") pets live on their own quiet `/pets/past` surface (the `:past`
  live action), reached by a subtle link from settings so memorial records stay findable
  without sitting beside the living (ADR-0003).
  """
  use Goodmao2Web, :live_view

  alias Goodmao2.Pets

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    ended? = socket.assigns.live_action == :past
    user = socket.assigns.current_scope.user
    pets = Pets.list_pets(user, ended: ended?)

    {:noreply,
     socket
     |> assign(:ended?, ended?)
     |> assign(:page_title, (ended? && gettext("Past pets")) || gettext("My pets"))
     |> stream(:pets, pets, reset: true)
     |> assign(:pets_empty?, pets == [])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <section id="pets-section" aria-labelledby="pets-heading">
        <header class="flex items-center justify-between gap-4">
          <h1 id="pets-heading" class="flex items-center gap-2 text-2xl font-semibold">
            <%= if @ended? do %>
              <.icon name="hero-heart" class="text-base-content/50 size-6" />
              {gettext("Past pets")}
            <% else %>
              {gettext("My pets")}
            <% end %>
          </h1>
          <.link
            :if={!@ended?}
            navigate={~p"/pets/new"}
            id="new-pet-button"
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-plus" class="size-4" /> {gettext("Add a pet")}
          </.link>
        </header>

        <p :if={@ended?} id="past-pets-intro" class="text-base-content/60 mt-2 text-sm">
          {gettext(
            "Companions whose care has ended. Their records and timelines are kept here, always."
          )}
        </p>

        <div id="pets" phx-update="stream" class="mt-4 grid gap-3 sm:grid-cols-2">
          <div class="hidden only:block text-base-content/60 py-10 text-center" id="pets-empty">
            <%= if @ended? do %>
              {gettext("No past pets. Records of pets whose care has ended appear here.")}
            <% else %>
              {gettext("No pets yet. Add your first companion to start their timeline.")}
            <% end %>
          </div>

          <.link
            :for={{dom_id, pet} <- @streams.pets}
            id={dom_id}
            navigate={~p"/pets/#{pet.id}"}
            class="pet-card card card-border bg-base-100 hover:border-primary transition-colors"
          >
            <div class="card-body p-4">
              <div class="flex items-center justify-between gap-2">
                <h2 class="pet-card-name card-title text-lg">{pet.name}</h2>
                <span class="pet-card-species badge badge-ghost badge-sm">
                  {translate_species(pet.species)}
                </span>
              </div>
              <p class="pet-card-meta text-base-content/60 text-sm">
                {[translate_sex(pet.sex), pet.breed, pet.color]
                |> Enum.filter(&(&1 && &1 != ""))
                |> Enum.join(" · ")}
              </p>
              <p
                :if={pet.lifecycle_status != "active"}
                class="pet-card-status text-base-content/60 mt-1 flex items-center gap-1 text-sm"
              >
                <.icon name={lifecycle_icon(pet.lifecycle_status)} class="size-4" />
                {translate_lifecycle(pet.lifecycle_status)}
                <span :if={pet.ended_at}>· {format_date(pet.ended_at)}</span>
              </p>
            </div>
          </.link>
        </div>

        <p :if={@ended?} class="mt-6">
          <.link navigate={~p"/pets"} id="past-pets-back" class="text-base-content/70 text-sm">
            <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back to your pets")}
          </.link>
        </p>
      </section>
    </Layouts.app>
    """
  end
end
