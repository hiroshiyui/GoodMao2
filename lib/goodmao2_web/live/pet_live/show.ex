defmodule Goodmao2Web.PetLive.Show do
  @moduledoc """
  A pet's page: header, one-tap QuickLog, and the live, filterable timeline.

  The timeline updates in real time via `Goodmao2.Logs` PubSub, so a co-caretaker
  logging "gave the pill" appears instantly for everyone watching the pet.
  """
  use Goodmao2Web, :live_view

  alias Goodmao2.{Logs, Pets}
  alias Goodmao2.Logs.LogEntry
  alias Goodmao2Web.CalendarGrid

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
         |> assign(:view, "list")
         |> assign(:cal_month, CalendarGrid.month_of(Date.utc_today()))
         |> assign(:selected_day, nil)
         |> assign(:month_entries, [])
         |> assign(:day_buckets, %{})
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

  # Load just the visible month grid's entries (with the active type filter) and bucket
  # them by UTC day for the calendar's per-day count and clinical-flag cues.
  defp load_month(socket) do
    user = socket.assigns.current_scope.user
    {from, to} = CalendarGrid.grid_range(socket.assigns.cal_month)

    entries =
      Logs.list_entries(user, socket.assigns.pet,
        type: socket.assigns.filter,
        from: from,
        to: to,
        limit: 500
      )

    socket
    |> assign(:month_entries, entries)
    |> assign(:day_buckets, day_buckets(entries))
  end

  defp day_buckets(entries) do
    Enum.reduce(entries, %{}, fn entry, acc ->
      day = DateTime.to_date(entry.occurred_at)
      info = Map.get(acc, day, %{count: 0, level: nil})

      Map.put(acc, day, %{
        count: info.count + 1,
        level: escalate(info.level, clinical_level(entry))
      })
    end)
  end

  @impl true
  def handle_event("filter", %{"type" => type}, socket) do
    socket = socket |> assign(:filter, type) |> load_entries()
    {:noreply, if(socket.assigns.view == "calendar", do: load_month(socket), else: socket)}
  end

  # Switch between the chronological list and the month grid. Returning to the list
  # re-streams (the container was removed from the DOM); opening the calendar loads its month.
  def handle_event("set_view", %{"view" => "calendar"}, socket) do
    {:noreply, socket |> assign(:view, "calendar") |> load_month()}
  end

  def handle_event("set_view", %{"view" => _list}, socket) do
    {:noreply, socket |> assign(:view, "list") |> assign(:selected_day, nil) |> load_entries()}
  end

  def handle_event("cal_month", %{"delta" => delta}, socket) do
    month = CalendarGrid.add_months(socket.assigns.cal_month, String.to_integer(delta))

    {:noreply, socket |> assign(:cal_month, month) |> assign(:selected_day, nil) |> load_month()}
  end

  def handle_event("select_day", %{"day" => day}, socket) do
    case Date.from_iso8601(day) do
      {:ok, date} -> {:noreply, assign(socket, :selected_day, date)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("clear_day", _params, socket) do
    {:noreply, assign(socket, :selected_day, nil)}
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
    socket =
      if visible_here?(socket, entry) and matches_filter?(entry, socket.assigns.filter) do
        socket |> stream_insert(:entries, entry, at: 0) |> assign(:entries_empty?, false)
      else
        socket
      end

    {:noreply, maybe_refresh_month(socket)}
  end

  def handle_info({:entry_updated, entry}, socket) do
    # An edit can flip visibility, so drop an entry this viewer may no longer see.
    socket =
      if visible_here?(socket, entry) do
        stream_insert(socket, :entries, entry)
      else
        stream_delete(socket, :entries, entry)
      end

    {:noreply, maybe_refresh_month(socket)}
  end

  def handle_info({:entry_deleted, entry}, socket) do
    {:noreply, socket |> stream_delete(:entries, entry) |> maybe_refresh_month()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # In calendar view, a live create/update/delete can change the month's day buckets — and
  # the drilled-down day list — so recompute from the DB. Cheap at a pet's log rate.
  defp maybe_refresh_month(%{assigns: %{view: "calendar"}} = socket), do: load_month(socket)
  defp maybe_refresh_month(socket), do: socket

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
        <div class="flex flex-wrap items-center justify-between gap-4">
          <h2 id="timeline-heading" class="text-lg font-semibold">{gettext("Timeline")}</h2>

          <div
            id="timeline-view-toggle"
            role="group"
            aria-label={gettext("Timeline view")}
            class="join"
          >
            <button
              type="button"
              id="view-list"
              phx-click="set_view"
              phx-value-view="list"
              aria-pressed={to_string(@view == "list")}
              class={[
                "join-item btn btn-sm",
                (@view == "list" && "btn-primary") || "btn-ghost"
              ]}
            >
              <.icon name="hero-list-bullet" class="size-4" /> {gettext("List")}
            </button>
            <button
              type="button"
              id="view-calendar"
              phx-click="set_view"
              phx-value-view="calendar"
              aria-pressed={to_string(@view == "calendar")}
              class={[
                "join-item btn btn-sm",
                (@view == "calendar" && "btn-primary") || "btn-ghost"
              ]}
            >
              <.icon name="hero-calendar-days" class="size-4" /> {gettext("Calendar")}
            </button>
          </div>
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

        <.log_calendar
          :if={@view == "calendar"}
          month={@cal_month}
          grid={CalendarGrid.month_grid(@cal_month)}
          buckets={@day_buckets}
          selected_day={@selected_day}
          today={Date.utc_today()}
          day_entries={selected_day_entries(@month_entries, @selected_day)}
          can_write?={@can_write?}
        />

        <ol :if={@view == "list"} id="timeline" phx-update="stream" class="mt-4 space-y-2">
          <li class="hidden only:block text-base-content/60 py-8 text-center" id="timeline-empty">
            {gettext("No entries yet. Use Quick log above to start recording.")}
          </li>
          <li
            :for={{dom_id, entry} <- @streams.entries}
            id={dom_id}
            class="timeline-entry card card-border bg-base-100"
          >
            <.timeline_entry_card entry={entry} can_write?={@can_write?} />
          </li>
        </ol>
      </section>
    </Layouts.app>
    """
  end

  ## Function components

  # One timeline entry's card body — shared by the streamed list and the calendar's
  # per-day drill-down so both render identically.
  attr :entry, :map, required: true
  attr :can_write?, :boolean, default: false

  defp timeline_entry_card(assigns) do
    ~H"""
    <div class="card-body flex-row items-start gap-3 p-3">
      <span class={"timeline-entry-icon mt-0.5 shrink-0 rounded-full bg-base-200 p-2 " <> entry_tone(@entry)}>
        <.icon name={log_type_icon(@entry.type)} class="size-4" />
      </span>
      <div class="min-w-0 flex-1">
        <div class="flex items-center gap-2">
          <span class="timeline-entry-type font-medium">{log_type_label(@entry.type)}</span>
          <span
            :if={@entry.visibility != "limited"}
            class="timeline-entry-visibility badge badge-ghost badge-xs"
          >
            {translate_visibility(@entry.visibility)}
          </span>
        </div>
        <p class="timeline-entry-summary text-sm break-words">{log_summary(@entry)}</p>
        <p
          :if={@entry.note}
          class="timeline-entry-note text-base-content/70 mt-1 text-sm break-words"
        >
          {@entry.note}
        </p>
        <p class="timeline-entry-time text-base-content/50 mt-1 text-xs">
          <time datetime={DateTime.to_iso8601(@entry.occurred_at)}>
            {format_datetime(@entry.occurred_at)}
          </time>
        </p>
      </div>
      <button
        :if={@can_write?}
        type="button"
        id={"delete-entry-#{@entry.id}"}
        phx-click="delete_entry"
        phx-value-id={@entry.id}
        data-confirm={gettext("Remove this entry?")}
        class="timeline-entry-delete btn btn-ghost btn-xs"
        aria-label={gettext("Remove entry")}
      >
        <.icon name="hero-trash" class="size-4" />
      </button>
    </div>
    """
  end

  # The month grid: prev/next nav, a Sunday-first weekday header, a 6×7 day table, and —
  # when a day is picked — that day's entries below.
  attr :month, Date, required: true
  attr :grid, :list, required: true
  attr :buckets, :map, required: true
  attr :selected_day, Date, default: nil
  attr :today, Date, required: true
  attr :day_entries, :list, default: []
  attr :can_write?, :boolean, default: false

  defp log_calendar(assigns) do
    ~H"""
    <div id="timeline-calendar" class="mt-4">
      <nav
        class="flex items-center justify-between gap-2"
        aria-label={gettext("Month navigation")}
      >
        <button
          type="button"
          id="cal-prev"
          phx-click="cal_month"
          phx-value-delta="-1"
          class="btn btn-ghost btn-sm btn-circle"
          aria-label={gettext("Previous month")}
        >
          <.icon name="hero-chevron-left" class="size-4" />
        </button>
        <span id="cal-month-label" class="font-semibold">{month_label(@month)}</span>
        <button
          type="button"
          id="cal-next"
          phx-click="cal_month"
          phx-value-delta="1"
          class="btn btn-ghost btn-sm btn-circle"
          aria-label={gettext("Next month")}
        >
          <.icon name="hero-chevron-right" class="size-4" />
        </button>
      </nav>

      <table class="mt-3 w-full table-fixed border-collapse">
        <caption class="sr-only">
          {gettext("Entries for %{month}", month: month_label(@month))}
        </caption>
        <thead>
          <tr>
            <th
              :for={i <- 0..6}
              scope="col"
              class="text-base-content/60 p-1 text-center text-xs font-semibold"
            >
              <abbr title={weekday_long(i)} class="no-underline">{weekday_short(i)}</abbr>
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :for={week <- @grid}>
            <td
              :for={date <- week}
              class="border-base-200 h-16 border p-0 align-top"
            >
              <.cal_cell
                date={date}
                month={@month}
                buckets={@buckets}
                selected_day={@selected_day}
                today={@today}
              />
            </td>
          </tr>
        </tbody>
      </table>

      <div :if={@selected_day} id="cal-day-detail" class="mt-4">
        <div class="flex items-center justify-between gap-2">
          <h3 id="cal-day-heading" class="font-semibold">
            <time datetime={Date.to_iso8601(@selected_day)}>{day_label(@selected_day)}</time>
          </h3>
          <button type="button" id="cal-day-clear" phx-click="clear_day" class="btn btn-ghost btn-xs">
            {gettext("Back to month")}
          </button>
        </div>
        <p :if={@day_entries == []} class="text-base-content/60 py-4 text-sm">
          {gettext("No entries on this day.")}
        </p>
        <ol :if={@day_entries != []} class="mt-2 space-y-2">
          <li
            :for={entry <- @day_entries}
            id={"day-entry-#{entry.id}"}
            class="timeline-entry card card-border bg-base-100"
          >
            <.timeline_entry_card entry={entry} can_write?={@can_write?} />
          </li>
        </ol>
      </div>
    </div>
    """
  end

  # A single day tile. Days with entries are keyboard-operable buttons that drill in; the
  # count pill and (for a flagged day) an icon carry the clinical cue — never colour alone.
  attr :date, Date, required: true
  attr :month, Date, required: true
  attr :buckets, :map, required: true
  attr :selected_day, Date, default: nil
  attr :today, Date, required: true

  defp cal_cell(assigns) do
    in_month =
      assigns.date.month == assigns.month.month and assigns.date.year == assigns.month.year

    assigns =
      assign(assigns,
        in_month: in_month,
        info: (in_month && Map.get(assigns.buckets, assigns.date)) || nil,
        today?: assigns.date == assigns.today,
        selected?: assigns.date == assigns.selected_day
      )

    ~H"""
    <button
      :if={@info}
      type="button"
      id={"cal-day-#{Date.to_iso8601(@date)}"}
      phx-click="select_day"
      phx-value-day={Date.to_iso8601(@date)}
      aria-current={(@selected? && "true") || (@today? && "date") || nil}
      aria-label={day_cell_aria(@date, @info)}
      class={[
        "cal-day flex h-full w-full flex-col justify-between p-1 text-left hover:bg-base-200",
        @selected? && "bg-base-300",
        @today? && "ring-primary ring-2 ring-inset"
      ]}
    >
      <span class="text-xs">{@date.day}</span>
      <span class="flex items-center gap-1" aria-hidden="true">
        <span class={["badge badge-sm", cal_count_class(@info.level)]}>{@info.count}</span>
        <.icon
          :if={@info.level == :urgent}
          name="hero-exclamation-triangle"
          class="text-error size-4"
        />
        <.icon :if={@info.level == :watch} name="hero-exclamation-circle" class="text-warning size-4" />
      </span>
    </button>
    <div
      :if={!@info}
      aria-current={(@today? && "date") || nil}
      class={[
        "cal-day flex h-full flex-col p-1",
        !@in_month && "text-base-content/30",
        @today? && "ring-primary ring-2 ring-inset"
      ]}
    >
      <span class="text-xs">{@date.day}</span>
    </div>
    """
  end

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
          class="text-base-content/60 mt-1 flex items-center gap-1 text-sm"
        >
          <.icon name={lifecycle_icon(@pet.lifecycle_status)} class="size-4" />
          {translate_lifecycle(@pet.lifecycle_status)}
          <span :if={@pet.ended_at}>
            · <time datetime={DateTime.to_iso8601(@pet.ended_at)}>{format_date(@pet.ended_at)}</time>
          </span>
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

  # The (already-loaded) month entries that fall on the picked day, UTC-bucketed like the grid.
  defp selected_day_entries(_entries, nil), do: []

  defp selected_day_entries(entries, %Date{} = day) do
    Enum.filter(entries, &(DateTime.to_date(&1.occurred_at) == day))
  end

  defp day_cell_aria(date, %{count: count, level: level}) do
    base =
      day_label(date) <>
        ": " <> ngettext("%{count} entry", "%{count} entries", count, count: count)

    case level do
      :urgent -> base <> ", " <> gettext("urgent")
      :watch -> base <> ", " <> gettext("worth watching")
      _ -> base
    end
  end

  defp cal_count_class(:urgent), do: "badge-error"
  defp cal_count_class(:watch), do: "badge-warning"
  defp cal_count_class(_), do: "badge-ghost"

  # A subtle colour tint for clinically-urgent entry types.
  defp entry_tone(%{type: "vomit"}), do: "text-warning"
  defp entry_tone(%{type: "symptom"}), do: "text-warning"
  defp entry_tone(%{type: "vet_note"}), do: "text-info"
  defp entry_tone(_), do: "text-base-content/70"
end
