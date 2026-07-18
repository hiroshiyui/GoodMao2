defmodule Goodmao2Web.PetLive.Show do
  @moduledoc """
  A pet's page: header, one-tap QuickLog, and the live, filterable timeline.

  The timeline updates in real time via `Goodmao2.Logs` PubSub, so a co-caretaker
  logging "gave the pill" appears instantly for everyone watching the pet.
  """
  use Goodmao2Web, :live_view

  alias Goodmao2.{Logs, Pets}
  alias Goodmao2.Logs.LogEntry

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_scope.user

    case Pets.fetch_pet(user, id) do
      {:ok, pet} ->
        if connected?(socket), do: Logs.subscribe(pet)

        role = Pets.effective_role(pet, user)

        {:ok,
         socket
         |> assign(:page_title, pet.name)
         |> assign(:pet, pet)
         |> assign(:role, role)
         |> assign(:history_hidden?, pet.history_hidden)
         |> assign(:can_write?, Pets.can?(pet, user, :write))
         |> assign(:can_manage?, Pets.can?(pet, user, :manage))
         |> assign(:filter, "all")
         |> assign(:quicklog_type, "food")
         |> assign(:quick_form, to_form(%{}, as: :log))
         |> assign(:quick_error, nil)
         |> load_entries()}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Pet not found."))
         |> push_navigate(to: ~p"/pets")}
    end
  end

  defp load_entries(socket) do
    user = socket.assigns.current_scope.user
    entries = Logs.list_entries(user, socket.assigns.pet, type: socket.assigns.filter)

    socket
    |> stream(:entries, entries, reset: true)
    |> assign(:entries_empty?, entries == [])
  end

  @impl true
  def handle_event("filter", %{"type" => type}, socket) do
    {:noreply, socket |> assign(:filter, type) |> load_entries()}
  end

  def handle_event("select_type", %{"type" => type}, socket) do
    {:noreply,
     socket
     |> assign(:quicklog_type, type)
     |> assign(:quick_form, to_form(%{}, as: :log))
     |> assign(:quick_error, nil)}
  end

  def handle_event("quicklog_change", %{"log" => params}, socket) do
    {:noreply, assign(socket, :quick_form, to_form(params, as: :log))}
  end

  def handle_event("quicklog", %{"log" => params}, socket) do
    save_quicklog(socket, socket.assigns.quicklog_type, params)
  end

  # One-tap shortcut: submit immediately with a preset data payload.
  def handle_event("quicktap", %{"type" => type} = params, socket) do
    data = Map.drop(params, ["type"])
    save_quicklog(socket, type, data)
  end

  def handle_event("delete_entry", %{"id" => id}, socket) do
    pet = socket.assigns.pet
    user = socket.assigns.current_scope.user

    with %LogEntry{} = entry <- Logs.get_entry(user, pet, id),
         {:ok, _} <- Logs.delete_entry(user, pet, entry) do
      {:noreply, put_flash(socket, :info, gettext("Entry removed."))}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not remove that entry."))}
    end
  end

  defp save_quicklog(socket, type, params) do
    pet = socket.assigns.pet
    user = socket.assigns.current_scope.user

    {note, params} = Map.pop(params, "note")
    {occurred_at, params} = Map.pop(params, "occurred_at")
    {visibility, data} = Map.pop(params, "visibility")

    attrs =
      %{
        "type" => type,
        "data" => data,
        "note" => blank_to_nil(note),
        "visibility" => visibility || "limited"
      }
      |> maybe_put("occurred_at", blank_to_nil(occurred_at))

    case Logs.create_entry(user, pet, attrs) do
      {:ok, _entry} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Logged."))
         |> assign(:quick_form, to_form(%{}, as: :log))
         |> assign(:quick_error, nil)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :quick_error, changeset_error_message(changeset))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to log for this pet."))}
    end
  end

  @impl true
  def handle_info({:entry_created, entry}, socket) do
    if visible_here?(socket, entry) and matches_filter?(entry, socket.assigns.filter) do
      {:noreply,
       socket |> stream_insert(:entries, entry, at: 0) |> assign(:entries_empty?, false)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:entry_updated, entry}, socket) do
    # An edit can flip visibility, so drop an entry this viewer may no longer see.
    if visible_here?(socket, entry) do
      {:noreply, stream_insert(socket, :entries, entry)}
    else
      {:noreply, stream_delete(socket, :entries, entry)}
    end
  end

  def handle_info({:entry_deleted, entry}, socket) do
    {:noreply, stream_delete(socket, :entries, entry)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Applies the same per-entry visibility rule as the DB read to PubSub-pushed entries.
  defp visible_here?(socket, entry) do
    user = socket.assigns.current_scope.user
    Logs.can_view_entry?(entry, user.id, socket.assigns.role)
  end

  defp matches_filter?(_entry, "all"), do: true
  defp matches_filter?(entry, type), do: entry.type == type

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp changeset_error_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.flat_map(fn {field, msgs} -> Enum.map(msgs, &"#{field} #{&1}") end)
    |> Enum.join("; ")
  end

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.pet_header pet={@pet} role={@role} can_manage?={@can_manage?} />

      <div
        :if={@history_hidden?}
        id="history-hidden-notice"
        role="status"
        class="alert alert-warning mt-4"
      >
        <.icon name="hero-eye-slash" class="size-5" />
        <span>
          {gettext(
            "This pet's history is hidden. The timeline is unavailable until an owner turns it back on from Edit."
          )}
        </span>
      </div>

      <section
        :if={@can_write? and not @history_hidden?}
        id="quicklog-section"
        aria-labelledby="quicklog-heading"
        class="card card-border bg-base-100 mt-4"
      >
        <div class="card-body p-4">
          <h2 id="quicklog-heading" class="text-lg font-semibold">{gettext("Quick log")}</h2>
          <p class="text-base-content/60 text-sm">
            {gettext("One tap to record what just happened.")}
          </p>

          <div
            id="quicklog-types"
            class="mt-3 flex flex-wrap gap-2"
            role="tablist"
            aria-label={gettext("Log type")}
          >
            <button
              :for={type <- LogEntry.quicklog_types()}
              type="button"
              id={"quicklog-type-#{type}"}
              phx-click="select_type"
              phx-value-type={type}
              role="tab"
              aria-selected={to_string(@quicklog_type == type)}
              class={[
                "quicklog-type-chip btn btn-sm",
                (@quicklog_type == type && "btn-primary") || "btn-ghost"
              ]}
            >
              <.icon name={log_type_icon(type)} class="size-4" /> {log_type_label(type)}
            </button>
          </div>

          <p :if={@quick_error} id="quicklog-error" class="text-error mt-3 text-sm">{@quick_error}</p>

          <.form
            for={@quick_form}
            id="quicklog-form"
            phx-change="quicklog_change"
            phx-submit="quicklog"
            class="mt-3 space-y-3"
          >
            <.quicklog_fields type={@quicklog_type} form={@quick_form} />

            <details class="quicklog-more">
              <summary class="cursor-pointer text-sm text-base-content/70">
                {gettext("Add note, time, or visibility")}
              </summary>
              <div class="mt-3 space-y-3">
                <%!-- A life log's note is its primary caption above, so skip the duplicate here. --%>
                <.input
                  :if={@quicklog_type != "life"}
                  field={@quick_form[:note]}
                  type="textarea"
                  label={gettext("Note")}
                  rows="2"
                />
                <div class="grid gap-3 sm:grid-cols-2">
                  <.input
                    field={@quick_form[:occurred_at]}
                    type="datetime-local"
                    label={gettext("When")}
                  />
                  <.input
                    :if={@role == "owner"}
                    field={@quick_form[:visibility]}
                    type="select"
                    label={gettext("Visibility")}
                    options={Enum.map(LogEntry.visibilities(), &{translate_visibility(&1), &1})}
                  />
                </div>
              </div>
            </details>

            <.button
              type="submit"
              id="quicklog-submit"
              class="btn btn-primary"
              phx-disable-with={gettext("Saving…")}
            >
              {gettext("Log %{type}", type: log_type_label(@quicklog_type))}
            </.button>
          </.form>
        </div>
      </section>

      <section
        :if={not @history_hidden?}
        id="timeline-section"
        aria-labelledby="timeline-heading"
        class="mt-6"
      >
        <div class="flex items-center justify-between gap-4">
          <h2 id="timeline-heading" class="text-lg font-semibold">{gettext("Timeline")}</h2>
        </div>

        <form id="timeline-filter" phx-change="filter" class="mt-2">
          <label for="timeline-filter-type" class="sr-only">{gettext("Filter by type")}</label>
          <select
            id="timeline-filter-type"
            name="type"
            class="select select-bordered select-sm w-auto"
          >
            <option value="all" selected={@filter == "all"}>{gettext("All types")}</option>
            <option :for={type <- LogEntry.types()} value={type} selected={@filter == type}>
              {log_type_label(type)}
            </option>
          </select>
        </form>

        <ol id="timeline" phx-update="stream" class="mt-4 space-y-2">
          <li class="hidden only:block text-base-content/60 py-8 text-center" id="timeline-empty">
            {gettext("No entries yet. Use Quick log above to start recording.")}
          </li>
          <li
            :for={{dom_id, entry} <- @streams.entries}
            id={dom_id}
            class="timeline-entry card card-border bg-base-100"
          >
            <div class="card-body flex-row items-start gap-3 p-3">
              <span class={"timeline-entry-icon mt-0.5 shrink-0 rounded-full bg-base-200 p-2 " <> entry_tone(entry)}>
                <.icon name={log_type_icon(entry.type)} class="size-4" />
              </span>
              <div class="min-w-0 flex-1">
                <div class="flex items-center gap-2">
                  <span class="timeline-entry-type font-medium">{log_type_label(entry.type)}</span>
                  <span
                    :if={entry.visibility != "limited"}
                    class="timeline-entry-visibility badge badge-ghost badge-xs"
                  >
                    {translate_visibility(entry.visibility)}
                  </span>
                </div>
                <p class="timeline-entry-summary text-sm break-words">{log_summary(entry)}</p>
                <p
                  :if={entry.note}
                  class="timeline-entry-note text-base-content/70 mt-1 text-sm break-words"
                >
                  {entry.note}
                </p>
                <p class="timeline-entry-time text-base-content/50 mt-1 text-xs">
                  {format_datetime(entry.occurred_at)}
                </p>
              </div>
              <button
                :if={@can_write?}
                type="button"
                id={"delete-entry-#{entry.id}"}
                phx-click="delete_entry"
                phx-value-id={entry.id}
                data-confirm={gettext("Remove this entry?")}
                class="timeline-entry-delete btn btn-ghost btn-xs"
                aria-label={gettext("Remove entry")}
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </div>
          </li>
        </ol>
      </section>
    </Layouts.app>
    """
  end

  ## Function components

  attr :pet, :map, required: true
  attr :role, :string, default: nil
  attr :can_manage?, :boolean, default: false

  defp pet_header(assigns) do
    ~H"""
    <section
      id="pet-header"
      aria-labelledby="pet-name"
      class="flex flex-wrap items-start justify-between gap-4"
    >
      <div>
        <div class="flex items-center gap-2">
          <.link
            navigate={~p"/pets"}
            id="pet-back"
            class="btn btn-ghost btn-sm btn-circle"
            aria-label={gettext("Back to pets")}
          >
            <.icon name="hero-arrow-left" class="size-4" />
          </.link>
          <h1 id="pet-name" class="text-2xl font-semibold">{@pet.name}</h1>
          <span :if={@role} id="pet-role-badge" class="badge badge-ghost badge-sm">
            {translate_role(@role)}
          </span>
        </div>
        <p class="pet-header-meta text-base-content/60 mt-1 text-sm">
          {[translate_species(@pet.species), translate_sex(@pet.sex), @pet.breed, @pet.color]
          |> Enum.filter(&(&1 && &1 != ""))
          |> Enum.join(" · ")}
        </p>
        <p
          :if={@pet.lifecycle_status != "active"}
          id="pet-lifecycle"
          class="text-warning mt-1 text-sm"
        >
          {translate_lifecycle(@pet.lifecycle_status)}
          <span :if={@pet.ended_at}>· {format_date(@pet.ended_at)}</span>
        </p>
      </div>

      <nav :if={@can_manage?} id="pet-actions" class="flex gap-2" aria-label={gettext("Pet actions")}>
        <.link
          navigate={~p"/pets/#{@pet.id}/access"}
          id="pet-access-link"
          class="btn btn-ghost btn-sm"
        >
          <.icon name="hero-user-group" class="size-4" /> {gettext("Sharing")}
        </.link>
        <.link navigate={~p"/pets/#{@pet.id}/edit"} id="pet-edit-link" class="btn btn-ghost btn-sm">
          <.icon name="hero-pencil-square" class="size-4" /> {gettext("Edit")}
        </.link>
      </nav>
    </section>
    """
  end

  attr :type, :string, required: true
  attr :form, :map, required: true

  defp quicklog_fields(%{type: "food"} = assigns) do
    ~H"""
    <div class="grid gap-3 sm:grid-cols-3">
      <.input
        field={@form[:amount]}
        type="select"
        label={gettext("Amount")}
        options={[
          {gettext("Ate fully"), "full"},
          {gettext("Ate partially"), "partial"},
          {gettext("Refused"), "refused"}
        ]}
      />
      <.input field={@form[:food_type]} type="text" label={gettext("Food")} />
      <.input field={@form[:portion_grams]} type="number" label={gettext("Portion (g)")} min="0" />
    </div>
    """
  end

  defp quicklog_fields(%{type: "water"} = assigns) do
    ~H"""
    <div class="grid gap-3 sm:grid-cols-2">
      <.input
        field={@form[:amount]}
        type="select"
        label={gettext("Intake")}
        options={[{gettext("Normal"), "normal"}, {gettext("Low"), "low"}, {gettext("High"), "high"}]}
      />
      <.input field={@form[:volume_ml]} type="number" label={gettext("Volume (ml)")} min="0" />
    </div>
    """
  end

  defp quicklog_fields(%{type: "bathroom"} = assigns) do
    ~H"""
    <div class="grid gap-3 sm:grid-cols-2">
      <.input
        field={@form[:kind]}
        type="select"
        label={gettext("Kind")}
        options={[{gettext("Urine"), "urine"}, {gettext("Stool"), "stool"}]}
      />
      <.input field={@form[:consistency]} type="text" label={gettext("Consistency")} />
    </div>
    <div class="flex flex-wrap gap-4">
      <.input field={@form[:has_blood]} type="checkbox" label={gettext("Blood present")} />
      <.input
        field={@form[:straining]}
        type="checkbox"
        label={gettext("Straining (⚠ cat emergency)")}
      />
    </div>
    """
  end

  defp quicklog_fields(%{type: "vomit"} = assigns) do
    ~H"""
    <div class="grid gap-3 sm:grid-cols-2">
      <.input
        field={@form[:count]}
        type="number"
        label={gettext("Episodes")}
        min="1"
        value={@form[:count].value || "1"}
      />
      <.input field={@form[:contents]} type="text" label={gettext("Contents")} />
    </div>
    """
  end

  defp quicklog_fields(%{type: "weight"} = assigns) do
    ~H"""
    <.input
      field={@form[:weight_grams]}
      type="number"
      label={gettext("Weight (grams)")}
      min="0"
      required
    />
    """
  end

  defp quicklog_fields(%{type: "energy"} = assigns) do
    ~H"""
    <div class="grid gap-3 sm:grid-cols-2">
      <.input
        field={@form[:level]}
        type="select"
        label={gettext("Energy level")}
        options={Enum.map(1..5, &{"#{&1}", "#{&1}"})}
      />
      <.input field={@form[:mood]} type="text" label={gettext("Mood")} />
    </div>
    """
  end

  defp quicklog_fields(%{type: "medication"} = assigns) do
    ~H"""
    <div class="grid gap-3 sm:grid-cols-2">
      <.input field={@form[:medication_name]} type="text" label={gettext("Medication")} required />
      <.input field={@form[:dose]} type="text" label={gettext("Dose")} required />
    </div>
    """
  end

  defp quicklog_fields(%{type: "symptom"} = assigns) do
    ~H"""
    <div class="grid gap-3 sm:grid-cols-2">
      <.input field={@form[:symptom]} type="text" label={gettext("Symptom")} required />
      <.input
        field={@form[:severity]}
        type="select"
        label={gettext("Severity")}
        options={Enum.map(1..5, &{"#{&1}", "#{&1}"})}
      />
    </div>
    """
  end

  defp quicklog_fields(%{type: "life"} = assigns) do
    ~H"""
    <.input
      field={@form[:note]}
      type="textarea"
      label={gettext("What happened?")}
      rows="3"
      required
    />
    """
  end

  defp quicklog_fields(assigns), do: ~H""

  # A subtle colour tint for clinically-urgent entry types.
  defp entry_tone(%{type: "vomit"}), do: "text-warning"
  defp entry_tone(%{type: "symptom"}), do: "text-warning"
  defp entry_tone(%{type: "vet_note"}), do: "text-info"
  defp entry_tone(_), do: "text-base-content/70"
end
