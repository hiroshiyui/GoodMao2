defmodule Goodmao2Web.PetLive.Show do
  @moduledoc """
  A pet's page: header, one-tap QuickLog, and the live, filterable timeline.

  The timeline updates in real time via `Goodmao2.Logs` PubSub, so a co-caretaker
  logging "gave the pill" appears instantly for everyone watching the pet.
  """
  use Goodmao2Web, :live_view

  alias Goodmao2.{Accounts, Logs, Media, Pets}
  alias Goodmao2.Accounts.User
  alias Goodmao2.Media.Avatars
  alias Goodmao2.Logs.LogEntry
  alias Goodmao2Web.CalendarGrid

  # The page sizes offered by the timeline's "per page" dropdown, sourced from the User schema so
  # the whitelist and the persisted preference share one definition. The first is the default;
  # any other value is rejected back to it, so a crafted select can't request an unbounded page.
  @page_sizes User.timeline_page_sizes()

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
         |> assign(:avatar_meta, Avatars.meta("pet", pet.id))
         |> assign(:avatar_menu_open, false)
         |> assign(:filter, "all")
         |> assign(:page, 1)
         |> assign(:page_size, user.timeline_page_size || hd(@page_sizes))
         |> assign(:has_next?, false)
         |> assign(:visible_ids, MapSet.new())
         |> assign(:view, "list")
         |> assign(:cal_month, CalendarGrid.month_of(Date.utc_today()))
         |> assign(:selected_day, nil)
         |> assign(:month_entries, [])
         |> assign(:day_buckets, %{})
         |> assign(:quicklog_type, "food")
         |> assign(:quick_form, to_form(%{}, as: :log))
         |> assign(:quick_error, nil)
         |> assign(:weight_series, [])
         |> allow_upload(:media,
           accept: ~w(.jpg .jpeg .png .gif .webp .mp4 .webm),
           max_entries: Media.config(:max_entries),
           # The larger per-kind cap gates the client upload; the purifier re-checks each file
           # against its own image/video byte cap (Media.Limits), so this is only a coarse ceiling.
           max_file_size: Media.Limits.get(:max_video_bytes)
         )
         |> allow_upload(:avatar,
           accept: ~w(.jpg .jpeg .png .gif .webp),
           max_entries: 1,
           max_file_size: Media.Limits.get(:max_image_bytes)
         )
         |> load_entries()
         |> load_weight()}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Pet not found."))
         |> push_navigate(to: ~p"/pets")}
    end
  end

  # Load one page of the timeline. We over-fetch by one row to know whether a *next* page
  # exists without a separate count query; `visible_ids` is the exact set of ids currently on
  # the page, so live PubSub edits/deletes only touch entries actually shown (see handle_info).
  defp load_entries(socket) do
    user = socket.assigns.current_scope.user
    size = socket.assigns.page_size
    offset = (socket.assigns.page - 1) * size

    fetched =
      Logs.list_entries(user, socket.assigns.pet,
        type: socket.assigns.filter,
        limit: size + 1,
        offset: offset
      )

    entries = Enum.take(fetched, size)

    socket
    |> stream(:entries, entries, reset: true)
    |> assign(:entries_empty?, entries == [])
    |> assign(:has_next?, length(fetched) > size)
    |> assign(:visible_ids, MapSet.new(entries, & &1.id))
  end

  # The weight-trend series is independent of the timeline's type filter — it always shows
  # every weight measurement — so it loads on its own, not inside load_entries/1.
  defp load_weight(socket) do
    user = socket.assigns.current_scope.user
    assign(socket, :weight_series, Logs.weight_series(user, socket.assigns.pet))
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
    |> assign(:day_buckets, day_buckets(entries, socket.assigns.timezone))
  end

  # Bucket entries by their **local** calendar day (ADR-0018) so a cell counts what the viewer
  # would call that day, matching the timeline rows. `grid_range/1` over-fetches by a day on each
  # side so entries near a local-midnight edge are present to bucket.
  defp day_buckets(entries, tz) do
    Enum.reduce(entries, %{}, fn entry, acc ->
      day = entry.occurred_at |> Goodmao2.Timezone.to_local(tz) |> DateTime.to_date()
      info = Map.get(acc, day, %{count: 0, level: nil})

      Map.put(acc, day, %{
        count: info.count + 1,
        level: escalate(info.level, clinical_level(entry))
      })
    end)
  end

  @impl true
  def handle_event("filter", %{"type" => type}, socket) do
    socket = socket |> assign(:filter, type) |> assign(:page, 1) |> load_entries()
    {:noreply, if(socket.assigns.view == "calendar", do: load_month(socket), else: socket)}
  end

  # The "per page" dropdown next to the filter — a new size restarts at page 1 and is persisted
  # as the user's preference so it sticks across visits and devices. The size is already
  # whitelisted, so the write is best-effort (the in-session size applies regardless).
  def handle_event("set_page_size", %{"size" => size}, socket) do
    size = parse_page_size(size)
    Accounts.update_timeline_page_size(socket.assigns.current_scope.user, size)

    {:noreply,
     socket
     |> assign(:page_size, size)
     |> assign(:page, 1)
     |> load_entries()}
  end

  def handle_event("timeline_page", %{"page" => page}, socket) do
    {:noreply,
     socket
     |> assign(:page, parse_page(page, socket.assigns.page))
     |> load_entries()
     |> push_event("scroll-to-timeline", %{})}
  end

  # Switch between the chronological list and the month grid. Returning to the list
  # re-streams (the container was removed from the DOM); opening the calendar loads its month.
  def handle_event("set_view", %{"view" => "calendar"}, socket) do
    {:noreply, socket |> assign(:view, "calendar") |> load_month()}
  end

  def handle_event("set_view", %{"view" => _list}, socket) do
    {:noreply,
     socket
     |> assign(:view, "list")
     |> assign(:selected_day, nil)
     |> assign(:page, 1)
     |> load_entries()}
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
    # Only honor a type this role may actually author, so a crafted event can't drop the
    # form into, e.g., the vet-only `vet_note` state for a co-caretaker. Creation is still
    # re-checked in `Logs.create_entry/3`.
    if type in LogEntry.quicklog_types(socket.assigns.role) do
      {:noreply,
       socket
       |> assign(:quicklog_type, type)
       |> assign(:quick_form, to_form(%{}, as: :log))
       |> assign(:quick_error, nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("quicklog_change", %{"log" => params}, socket) do
    {:noreply, assign(socket, :quick_form, to_form(params, as: :log))}
  end

  def handle_event("quicklog", %{"log" => params}, socket) do
    if socket.assigns.quicklog_type == "life" do
      save_life_log(socket, params)
    else
      save_quicklog(socket, socket.assigns.quicklog_type, params)
    end
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :media, ref)}
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

  ## Pet profile photo (ADR-0020) — managers only; staged then purified async.

  # The uploader popover's open state is server-owned so it survives the re-render a file
  # selection triggers (a native <details> would snap shut). Click the avatar to toggle.
  def handle_event("toggle_avatar_menu", _params, socket) do
    {:noreply, update(socket, :avatar_menu_open, &(not &1))}
  end

  def handle_event("validate_avatar", _params, socket), do: {:noreply, socket}

  def handle_event("save_avatar", params, socket) do
    pet = socket.assigns.pet
    user = socket.assigns.current_scope.user

    staged =
      consume_uploaded_entries(socket, :avatar, fn %{path: path}, _entry ->
        {:ok, Media.stage_upload(path)}
      end)

    case staged do
      [{:ok, token}] ->
        case Avatars.set_avatar("pet", pet.id, user, token, params["crop"]) do
          {:ok, avatar} ->
            {:noreply,
             socket
             |> assign(:avatar_meta, %{status: avatar.status, version: Avatars.version(avatar)})
             |> assign(:avatar_menu_open, false)
             |> put_flash(:info, gettext("Photo uploaded — it will appear once processed."))}

          {:error, _} ->
            Media.unstage_upload(token)
            {:noreply, put_flash(socket, :error, gettext("Couldn't update this pet's photo."))}
        end

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Please choose an image to upload."))}
    end
  end

  def handle_event("remove_avatar", _params, socket) do
    pet = socket.assigns.pet
    user = socket.assigns.current_scope.user

    case Avatars.delete_avatar("pet", pet.id, user) do
      :ok ->
        {:noreply,
         socket
         |> assign(:avatar_meta, nil)
         |> assign(:avatar_menu_open, false)
         |> put_flash(:info, gettext("Profile photo removed."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("You can't change this pet's photo."))}
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
        "data" => convert_weight_input(data, type, pet.weight_unit),
        "note" => blank_to_nil(note),
        "visibility" => visibility || "limited"
      }
      |> put_local_occurred_at(occurred_at, socket.assigns.timezone)

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

  # A daily-life log may carry photos/videos (ADR-0005). Stage each raw upload and create the
  # entry immediately; the ffmpeg purification runs off the request path in `Media.PurifyWorker`,
  # which attaches each media row and re-broadcasts so it appears live. If the log itself fails to
  # create, the staged uploads are discarded.
  defp save_life_log(socket, params) do
    pet = socket.assigns.pet
    user = socket.assigns.current_scope.user

    attrs =
      %{
        "note" => blank_to_nil(Map.get(params, "note")),
        "visibility" => Map.get(params, "visibility") || "limited"
      }
      |> put_local_occurred_at(Map.get(params, "occurred_at"), socket.assigns.timezone)

    staged =
      socket
      |> consume_uploaded_entries(:media, fn %{path: path}, _entry ->
        {:ok, Media.stage_upload(path)}
      end)
      |> Enum.flat_map(fn
        {:ok, token} -> [%{token: token}]
        _ -> []
      end)

    case Media.create_life_log(user, pet, attrs, staged) do
      {:ok, _entry} = ok ->
        handle_life_result(socket, ok)

      error ->
        Enum.each(staged, &Media.unstage_upload(&1.token))
        handle_life_result(socket, error)
    end
  end

  defp handle_life_result(socket, {:ok, _entry}) do
    {:noreply,
     socket
     |> put_flash(:info, gettext("Logged."))
     |> assign(:quick_form, to_form(%{}, as: :log))
     |> assign(:quick_error, nil)}
  end

  defp handle_life_result(socket, {:error, :rate_limited}) do
    {:noreply,
     put_flash(
       socket,
       :error,
       gettext("You've uploaded a lot recently — please try again later.")
     )}
  end

  defp handle_life_result(socket, {:error, :unauthorized}) do
    {:noreply, put_flash(socket, :error, gettext("You are not allowed to log for this pet."))}
  end

  defp handle_life_result(socket, {:error, %Ecto.Changeset{} = changeset}) do
    {:noreply, assign(socket, :quick_error, changeset_error_message(changeset))}
  end

  defp handle_life_result(socket, {:error, _reason}) do
    {:noreply, put_flash(socket, :error, gettext("Couldn't save that entry. Please try again."))}
  end

  @doc false
  def upload_error_to_string(:too_large), do: gettext("File is too large.")
  def upload_error_to_string(:too_many_files), do: gettext("Too many files.")
  def upload_error_to_string(:not_accepted), do: gettext("That file type isn't accepted.")
  def upload_error_to_string(_), do: gettext("That file can't be used.")

  # Live updates only mutate the streamed list on **page 1** in list view — a new entry belongs
  # at the top of the newest page. Deeper pages are a stable offset slice, so a create there is
  # ignored (it'll be seen by paging or on the next reset). Edits/deletes act only on entries in
  # `visible_ids` — the ids actually on this page — so an edit to an off-page entry can't inject
  # a stray row. The calendar and weight chart refresh regardless of the active page.
  @impl true
  def handle_info({:entry_created, entry}, socket) do
    socket =
      if socket.assigns.view == "list" and socket.assigns.page == 1 and
           visible_here?(socket, entry) and matches_filter?(entry, socket.assigns.filter) do
        socket
        |> stream_insert(:entries, entry, at: 0)
        |> update(:visible_ids, &MapSet.put(&1, entry.id))
        |> assign(:entries_empty?, false)
      else
        socket
      end

    {:noreply, socket |> maybe_refresh_month() |> maybe_refresh_weight(entry)}
  end

  def handle_info({:entry_updated, entry}, socket) do
    # An edit can flip visibility, so drop an entry this viewer may no longer see.
    socket =
      cond do
        not MapSet.member?(socket.assigns.visible_ids, entry.id) ->
          socket

        visible_here?(socket, entry) ->
          stream_insert(socket, :entries, entry)

        true ->
          socket
          |> stream_delete(:entries, entry)
          |> update(:visible_ids, &MapSet.delete(&1, entry.id))
      end

    {:noreply, socket |> maybe_refresh_month() |> maybe_refresh_weight(entry)}
  end

  def handle_info({:entry_deleted, entry}, socket) do
    socket =
      if MapSet.member?(socket.assigns.visible_ids, entry.id) do
        socket
        |> stream_delete(:entries, entry)
        |> update(:visible_ids, &MapSet.delete(&1, entry.id))
      else
        socket
      end

    {:noreply, socket |> maybe_refresh_month() |> maybe_refresh_weight(entry)}
  end

  # A pet avatar rides the pet's timeline topic (ADR-0020); a non-ready meta ⇒ show the fallback.
  def handle_info({:avatar_updated, "pet", _id, meta}, socket) do
    meta = if meta.status == "ready", do: meta, else: nil
    {:noreply, assign(socket, :avatar_meta, meta)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # In calendar view, a live create/update/delete can change the month's day buckets — and
  # the drilled-down day list — so recompute from the DB. Cheap at a pet's log rate.
  defp maybe_refresh_month(%{assigns: %{view: "calendar"}} = socket), do: load_month(socket)
  defp maybe_refresh_month(socket), do: socket

  # A weight entry created/edited/deleted anywhere changes the trend; reload it. Other types
  # leave the chart untouched.
  defp maybe_refresh_weight(socket, %{type: "weight"}), do: load_weight(socket)
  defp maybe_refresh_weight(socket, _entry), do: socket

  # Applies the same per-entry visibility rule as the DB read to PubSub-pushed entries.
  defp visible_here?(socket, entry) do
    user = socket.assigns.current_scope.user
    Logs.can_view_entry?(entry, user.id, socket.assigns.role)
  end

  defp matches_filter?(_entry, "all"), do: true
  defp matches_filter?(entry, type), do: entry.type == type

  # The weight field is entered in the pet's `weight_unit`; convert it to canonical grams for
  # storage (`data["weight_grams"]`) — roadmap §8.
  defp convert_weight_input(%{"weight" => value} = data, "weight", unit) do
    data
    |> Map.delete("weight")
    |> Map.put("weight_grams", Goodmao2Web.Helpers.weight_to_grams(value, unit))
  end

  defp convert_weight_input(data, _type, _unit), do: data

  # The datetime-local input carries a wall-clock value in the viewer's timezone; interpret it
  # in `tz` and store the UTC instant (ADR-0018). A blank value is omitted (the changeset then
  # defaults to now/UTC); an unparseable value is passed through so the changeset rejects it.
  defp put_local_occurred_at(attrs, occurred_at, tz) do
    case blank_to_nil(occurred_at) do
      nil ->
        attrs

      str ->
        case Goodmao2.Timezone.local_naive_to_utc(str, tz) do
          {:ok, dt} -> Map.put(attrs, "occurred_at", dt)
          :error -> Map.put(attrs, "occurred_at", str)
        end
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  # Whitelist the page size to the offered set; anything else falls back to the default.
  defp parse_page_size(size) do
    case Integer.parse(to_string(size)) do
      {n, ""} when n in @page_sizes -> n
      _ -> hd(@page_sizes)
    end
  end

  # A page must be a positive integer; a bad value keeps the current page.
  defp parse_page(page, current) do
    case Integer.parse(to_string(page)) do
      {n, ""} when n >= 1 -> n
      _ -> current
    end
  end

  defp changeset_error_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.flat_map(fn {field, msgs} -> Enum.map(msgs, &"#{field} #{&1}") end)
    |> Enum.join("; ")
  end

  ## Render

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:presets, quicktap_presets(assigns.quicklog_type))
      |> assign(:page_sizes, @page_sizes)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      unread_notifications={@unread_notifications}
      unread_messages={@unread_messages}
      current_user_avatar={@current_user_avatar}
    >
      <.pet_header
        pet={@pet}
        role={@role}
        can_manage?={@can_manage?}
        avatar_meta={@avatar_meta}
        avatar_menu_open={@avatar_menu_open}
        avatar_upload={@uploads.avatar}
      />

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
              :for={type <- LogEntry.quicklog_types(@role)}
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

          <%!-- Fast path: each common value is its own button that logs in a single tap. --%>
          <div
            :if={@presets != []}
            id="quicktap-buttons"
            class="mt-3 flex flex-wrap gap-2"
            role="group"
            aria-label={gettext("Quick log shortcuts")}
          >
            <button
              :for={preset <- @presets}
              type="button"
              id={"quicktap-#{@quicklog_type}-#{preset.key}"}
              phx-click="quicktap"
              phx-value-type={@quicklog_type}
              {quicktap_value_attrs(preset.data)}
              phx-disable-with={gettext("Saving…")}
              class="quicktap-btn btn btn-sm btn-primary btn-outline"
            >
              {preset.label}
            </button>
          </div>

          <%!-- Manual path: full fields + note/time/visibility. Behind a disclosure when a
               fast path exists, shown directly for types that need real input. --%>
          <details :if={@presets != []} class="quicklog-more-options mt-3">
            <summary class="cursor-pointer text-sm text-base-content/70">
              {gettext("More options")}
            </summary>
            <.quicklog_form
              type={@quicklog_type}
              form={@quick_form}
              role={@role}
              weight_unit={@pet.weight_unit}
              collapse_extras={false}
            />
          </details>

          <.quicklog_form
            :if={@presets == []}
            type={@quicklog_type}
            form={@quick_form}
            role={@role}
            weight_unit={@pet.weight_unit}
            uploads={@uploads}
          />
        </div>
      </section>

      <.weight_chart
        :if={not @history_hidden? and length(@weight_series) >= 2}
        series={@weight_series}
        unit={@pet.weight_unit}
      />

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

        <div class="mt-2 flex flex-wrap items-center gap-2">
          <form id="timeline-filter" phx-change="filter">
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

          <form :if={@view == "list"} id="timeline-page-size" phx-change="set_page_size">
            <label for="timeline-page-size-select" class="sr-only">
              {gettext("Entries per page")}
            </label>
            <select
              id="timeline-page-size-select"
              name="size"
              class="select select-bordered select-sm w-auto"
            >
              <option :for={n <- @page_sizes} value={n} selected={@page_size == n}>
                {gettext("%{count} per page", count: n)}
              </option>
            </select>
          </form>
        </div>

        <.log_calendar
          :if={@view == "calendar"}
          month={@cal_month}
          grid={CalendarGrid.month_grid(@cal_month)}
          buckets={@day_buckets}
          selected_day={@selected_day}
          today={Date.utc_today()}
          day_entries={selected_day_entries(@month_entries, @selected_day, @timezone)}
          can_write?={@can_write?}
          weight_unit={@pet.weight_unit}
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
            <.timeline_entry_card
              entry={entry}
              can_write?={@can_write?}
              weight_unit={@pet.weight_unit}
            />
          </li>
        </ol>

        <nav
          :if={@view == "list" and (@page > 1 or @has_next?)}
          id="timeline-pager"
          class="mt-4 flex items-center justify-between gap-2 text-sm"
          aria-label={gettext("Timeline pages")}
        >
          <button
            type="button"
            id="timeline-page-prev"
            phx-click="timeline_page"
            phx-value-page={@page - 1}
            disabled={@page <= 1}
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-arrow-left" class="size-4" /> {gettext("Previous")}
          </button>

          <span id="timeline-page-status" class="text-base-content/60 tabular-nums">
            {gettext("Page %{page}", page: @page)}
          </span>

          <button
            type="button"
            id="timeline-page-next"
            phx-click="timeline_page"
            phx-value-page={@page + 1}
            disabled={not @has_next?}
            class="btn btn-ghost btn-sm"
          >
            {gettext("Next")} <.icon name="hero-arrow-right" class="size-4" />
          </button>
        </nav>
      </section>
    </Layouts.app>
    """
  end

  ## Function components

  # One timeline entry's card body — shared by the streamed list and the calendar's
  # per-day drill-down so both render identically.
  attr :entry, :map, required: true
  attr :can_write?, :boolean, default: false
  attr :weight_unit, :string, default: "kilograms"

  defp timeline_entry_card(assigns) do
    assigns = assign(assigns, :flags, clinical_flags(assigns.entry))

    ~H"""
    <div class="card-body flex-row items-start gap-3 p-3">
      <span class={"timeline-entry-icon mt-0.5 shrink-0 rounded-full bg-base-200 p-2 " <> entry_tone(@entry)}>
        <.icon name={log_type_icon(@entry.type)} class="size-4" />
      </span>
      <div class="min-w-0 flex-1">
        <div class="flex flex-wrap items-center gap-2">
          <span class="timeline-entry-type font-medium">{log_type_label(@entry.type)}</span>
          <ul
            :if={@flags != []}
            class="clinical-flags flex flex-wrap gap-1"
            aria-label={gettext("Clinical flags")}
          >
            <li
              :for={flag <- @flags}
              class={["clinical-flag badge badge-sm gap-1", clinical_flag_class(flag.level)]}
            >
              <.icon name={flag.icon} class="size-3" /> {flag.label}
            </li>
          </ul>
          <span
            :if={@entry.visibility != "limited"}
            class="timeline-entry-visibility badge badge-ghost badge-xs"
          >
            {translate_visibility(@entry.visibility)}
          </span>
        </div>
        <p class="timeline-entry-summary text-sm break-words">
          {log_summary(@entry, @weight_unit)}
        </p>
        <p
          :if={@entry.note}
          class="timeline-entry-note text-base-content/70 mt-1 text-sm break-words"
        >
          {@entry.note}
        </p>
        <.media_grid :if={@entry.media_assets != []} assets={@entry.media_assets} />
        <p class="timeline-entry-time text-base-content/50 mt-1 text-xs">
          <time datetime={DateTime.to_iso8601(@entry.occurred_at)}>
            {format_datetime(@entry.occurred_at)}
          </time>
          <span :if={@entry.edit_count > 0} class="timeline-entry-edited">· {gettext("edited")}</span>
        </p>
      </div>
      <div class="flex shrink-0 gap-1">
        <.link
          navigate={~p"/pets/#{@entry.pet_id}/logs/#{@entry.id}"}
          id={"entry-detail-#{@entry.id}"}
          class="timeline-entry-detail btn btn-ghost btn-xs"
          aria-label={gettext("Edit entry or view its history")}
        >
          <.icon name="hero-pencil-square" class="size-4" />
        </.link>
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
  attr :weight_unit, :string, default: "kilograms"

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
            <.timeline_entry_card entry={entry} can_write?={@can_write?} weight_unit={@weight_unit} />
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
  attr :avatar_meta, :map, default: nil
  attr :avatar_menu_open, :boolean, default: false
  attr :avatar_upload, :map, required: true

  defp pet_header(assigns) do
    ~H"""
    <section
      id="pet-header"
      aria-labelledby="pet-name"
      class="flex flex-wrap items-start justify-between gap-4"
    >
      <div class="flex items-start gap-3">
        <div class="relative flex flex-col items-center gap-1">
          <%!-- For a manager the avatar is a click-to-open trigger for the uploader popover.
                The open state is a server assign (not a native <details>) so it survives the
                re-render a file selection triggers; everyone else sees the avatar plain. --%>
          <button
            :if={@can_manage?}
            type="button"
            id="pet-avatar-trigger"
            phx-click="toggle_avatar_menu"
            aria-expanded={to_string(@avatar_menu_open)}
            aria-haspopup="menu"
            title={gettext("Change profile photo")}
            aria-label={gettext("Change profile photo")}
            class="cursor-pointer rounded-full focus-visible:outline-none"
          >
            <.avatar
              owner_type="pet"
              owner_id={@pet.id}
              name={@pet.name}
              meta={@avatar_meta}
              size={:xl}
            />
          </button>

          <.avatar
            :if={!@can_manage?}
            owner_type="pet"
            owner_id={@pet.id}
            name={@pet.name}
            meta={@avatar_meta}
            size={:xl}
          />

          <.form
            :if={@can_manage? and @avatar_menu_open}
            for={%{}}
            id="pet-avatar-form"
            phx-submit="save_avatar"
            phx-change="validate_avatar"
            class="absolute top-full z-40 mt-2 flex w-72 flex-col gap-2 rounded-box border border-base-200 bg-base-100 p-3 shadow"
          >
            <.live_file_input upload={@avatar_upload} class="file-input file-input-sm w-full" />
            <.avatar_cropper id="pet-avatar-cropper" />
            <div class="flex gap-2">
              <button type="submit" class="btn btn-sm btn-primary" phx-disable-with="…">
                {gettext("Set photo")}
              </button>
              <button
                :if={@avatar_meta}
                type="button"
                class="btn btn-sm"
                phx-click="remove_avatar"
                data-confirm={gettext("Remove this pet's photo?")}
              >
                {gettext("Remove")}
              </button>
            </div>
          </.form>

          <p :if={@avatar_meta[:status] == "processing"} class="text-base-content/60 text-xs">
            {gettext("Processing…")}
          </p>
        </div>
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
              ·
              <time datetime={DateTime.to_iso8601(@pet.ended_at)}>{format_date(@pet.ended_at)}</time>
            </span>
          </p>
        </div>
      </div>

      <nav id="pet-actions" class="flex gap-2" aria-label={gettext("Pet actions")}>
        <.link
          navigate={~p"/pets/#{@pet.id}/medications"}
          id="pet-medications-link"
          class="btn btn-ghost btn-sm"
        >
          <.icon name="hero-beaker" class="size-4" /> {gettext("Medications")}
        </.link>
        <.link
          navigate={~p"/pets/#{@pet.id}/reports"}
          id="pet-reports-link"
          class="btn btn-ghost btn-sm"
        >
          <.icon name="hero-document-text" class="size-4" /> {gettext("Reports")}
        </.link>
        <.link
          :if={@can_manage?}
          navigate={~p"/pets/#{@pet.id}/access"}
          id="pet-access-link"
          class="btn btn-ghost btn-sm"
        >
          <.icon name="hero-user-group" class="size-4" /> {gettext("Sharing")}
        </.link>
        <.link
          :if={@can_manage?}
          navigate={~p"/pets/#{@pet.id}/edit"}
          id="pet-edit-link"
          class="btn btn-ghost btn-sm"
        >
          <.icon name="hero-pencil-square" class="size-4" /> {gettext("Edit")}
        </.link>
      </nav>
    </section>
    """
  end

  # The full manual log form: the type's structured fields, its extra context (note / time /
  # visibility), and the submit button. `collapse_extras` tucks the extras behind their own
  # disclosure when the form itself is already shown directly (types with no one-tap path);
  # inside the "More options" disclosure it shows them inline to avoid nested disclosures.
  attr :type, :string, required: true
  attr :form, :map, required: true
  attr :role, :string, required: true
  attr :weight_unit, :string, default: "kilograms"
  attr :collapse_extras, :boolean, default: true
  attr :uploads, :any, default: nil

  defp quicklog_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id="quicklog-form"
      phx-change="quicklog_change"
      phx-submit="quicklog"
      class="mt-3 space-y-3"
    >
      <.log_fields type={@type} form={@form} weight_unit={@weight_unit} />

      <div :if={@type == "life" and @uploads} id="life-media-upload" class="space-y-2">
        <label for={@uploads.media.ref} class="fieldset-label text-sm">
          {gettext("Photos or video")}
        </label>
        <.live_file_input upload={@uploads.media} class="file-input file-input-bordered w-full" />
        <p class="text-base-content/50 text-xs">{gettext("JPEG, PNG, GIF, WEBP, MP4, or WEBM.")}</p>
        <ul class="space-y-1">
          <li
            :for={entry <- @uploads.media.entries}
            id={"upload-entry-#{entry.ref}"}
            class="flex items-center gap-2 text-sm"
          >
            <span class="min-w-0 flex-1 truncate">{entry.client_name}</span>
            <button
              type="button"
              phx-click="cancel_upload"
              phx-value-ref={entry.ref}
              class="btn btn-ghost btn-xs"
              aria-label={gettext("Remove file")}
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
            <span :for={err <- upload_errors(@uploads.media, entry)} class="text-error text-xs">
              {upload_error_to_string(err)}
            </span>
          </li>
        </ul>
        <p :for={err <- upload_errors(@uploads.media)} class="text-error text-xs">
          {upload_error_to_string(err)}
        </p>
      </div>

      <details :if={@collapse_extras} class="quicklog-more">
        <summary class="cursor-pointer text-sm text-base-content/70">
          {gettext("Add note, time, or visibility")}
        </summary>
        <div class="mt-3 space-y-3">
          <.quicklog_extras type={@type} form={@form} role={@role} />
        </div>
      </details>
      <div :if={not @collapse_extras} class="space-y-3">
        <.quicklog_extras type={@type} form={@form} role={@role} />
      </div>

      <.button
        type="submit"
        id="quicklog-submit"
        class="btn btn-primary"
        phx-disable-with={gettext("Saving…")}
      >
        {gettext("Log %{type}", type: log_type_label(@type))}
      </.button>
    </.form>
    """
  end

  # The optional context every log type can carry: a free-text note, a backdated time, and
  # (owners only) a visibility override.
  attr :type, :string, required: true
  attr :form, :map, required: true
  attr :role, :string, required: true

  defp quicklog_extras(assigns) do
    ~H"""
    <%!-- A life log's note is its primary caption above, so skip the duplicate here. --%>
    <.input
      :if={@type != "life"}
      field={@form[:note]}
      type="textarea"
      label={gettext("Note")}
      rows="2"
    />
    <div class="grid gap-3 sm:grid-cols-2">
      <.input field={@form[:occurred_at]} type="datetime-local" label={gettext("When")} />
      <.input
        :if={@role == "owner"}
        field={@form[:visibility]}
        type="select"
        label={gettext("Visibility")}
        options={Enum.map(LogEntry.visibilities(), &{translate_visibility(&1), &1})}
      />
    </div>
    """
  end

  # One-tap presets: the common values for a type, each logged immediately as its own button.
  # Types needing real input (weight, energy, medication, symptom, life) have none and fall
  # back to the manual form. Labels are self-descriptive so they work as accessible names.
  defp quicktap_presets("food") do
    [
      %{key: "full", label: gettext("Ate fully"), data: %{"amount" => "full"}},
      %{key: "partial", label: gettext("Ate partially"), data: %{"amount" => "partial"}},
      %{key: "refused", label: gettext("Refused"), data: %{"amount" => "refused"}}
    ]
  end

  defp quicktap_presets("water") do
    [
      %{key: "normal", label: gettext("Normal intake"), data: %{"amount" => "normal"}},
      %{key: "low", label: gettext("Low intake"), data: %{"amount" => "low"}},
      %{key: "high", label: gettext("High intake"), data: %{"amount" => "high"}}
    ]
  end

  defp quicktap_presets("bathroom") do
    [
      %{key: "urine", label: gettext("Urine"), data: %{"kind" => "urine"}},
      %{key: "stool", label: gettext("Stool"), data: %{"kind" => "stool"}}
    ]
  end

  defp quicktap_presets("vomit") do
    [%{key: "one", label: gettext("Vomited"), data: %{"count" => "1"}}]
  end

  defp quicktap_presets(_type), do: []

  # Spreads a preset's data map into the `phx-value-*` attributes the `quicktap` handler reads.
  defp quicktap_value_attrs(data) do
    Map.new(data, fn {key, value} -> {"phx-value-#{key}", value} end)
  end

  # The (already-loaded) month entries that fall on the picked day, bucketed by **local** day
  # like the grid (ADR-0018).
  defp selected_day_entries(_entries, nil, _tz), do: []

  defp selected_day_entries(entries, %Date{} = day, tz) do
    Enum.filter(entries, fn e ->
      e.occurred_at |> Goodmao2.Timezone.to_local(tz) |> DateTime.to_date() == day
    end)
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

  # Clinical-flag chip colour by level. Paired in the markup with a level-specific icon shape
  # (triangle = urgent, circle = watch) and the flag's text, so colour is never the sole cue.
  defp clinical_flag_class(:urgent), do: "badge-error"
  defp clinical_flag_class(:watch), do: "badge-warning"

  # A subtle colour tint for clinically-urgent entry types.
  defp entry_tone(%{type: "vomit"}), do: "text-warning"
  defp entry_tone(%{type: "symptom"}), do: "text-warning"
  defp entry_tone(%{type: "vet_note"}), do: "text-info"
  defp entry_tone(_), do: "text-base-content/70"
end
