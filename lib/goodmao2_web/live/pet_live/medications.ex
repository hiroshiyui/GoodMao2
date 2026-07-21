defmodule Goodmao2Web.PetLive.Medications do
  @moduledoc """
  Medication schedules and the "did anyone give the pill?" coordination for a pet (ADR-0019).

  Lists the pet's schedules with a create form and a live **doses-due** checklist: any caretaker
  with `:write` can mark a slot Given (which writes a normal `medication` timeline entry) or
  Skipped. Creating/editing a schedule needs `:write`; deleting needs `:manage` (owner). Reads are
  IDOR-hidden. Dose times are wall-clock in the schedule's own timezone; everything displays in
  the viewer's active zone (ADR-0018).
  """
  use Goodmao2Web, :live_view

  alias Goodmao2.Medications
  alias Goodmao2.Logs

  @impl true
  def mount(%{"pet_id" => pet_id}, _session, socket) do
    user = socket.assigns.current_scope.user

    case Goodmao2.Pets.fetch_pet(user, pet_id) do
      {:ok, pet} ->
        if connected?(socket), do: Logs.subscribe(pet)

        {:ok,
         socket
         |> assign(:pet, pet)
         |> assign(:page_title, gettext("Medications for %{name}", name: pet.name))
         |> assign(:can_write?, Goodmao2.Pets.can?(pet, user, :write))
         |> assign(:can_manage?, Goodmao2.Pets.can?(pet, user, :manage))
         |> assign(:schedule_form, blank_form())
         |> assign(:error, nil)
         |> load()}

      {:error, :not_found} ->
        {:ok,
         socket |> put_flash(:error, gettext("Pet not found.")) |> push_navigate(to: ~p"/pets")}
    end
  end

  defp blank_form, do: to_form(%{"times" => "", "interval_days" => "1"}, as: :schedule)

  defp load(socket) do
    user = socket.assigns.current_scope.user
    pet = socket.assigns.pet

    socket
    |> assign(:schedules, Medications.list_schedules(user, pet))
    |> assign(:doses, Medications.upcoming_doses(user, pet))
  end

  @impl true
  def handle_event("save_schedule", %{"schedule" => params}, socket) do
    user = socket.assigns.current_scope.user
    pet = socket.assigns.pet

    case parse_times(params["times"]) do
      {:ok, times} ->
        attrs =
          params
          |> Map.drop(["times"])
          |> Map.put("times_of_day", times)
          |> Map.put("timezone", params["timezone"] || socket.assigns.timezone)

        case Medications.create_schedule(user, pet, attrs) do
          {:ok, _schedule} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Schedule added."))
             |> assign(:schedule_form, blank_form())
             |> assign(:error, nil)
             |> load()}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign(socket, :error, changeset_error_message(changeset))}

          {:error, :unauthorized} ->
            {:noreply,
             put_flash(socket, :error, gettext("You are not allowed to manage medications here."))}
        end

      :error ->
        {:noreply,
         assign(socket, :error, gettext("Enter dose times as HH:MM, separated by commas."))}
    end
  end

  def handle_event("give_dose", %{"id" => id}, socket) do
    with_dose(socket, id, fn dose ->
      Medications.mark_dose_given(socket.assigns.current_scope.user, socket.assigns.pet, dose)
    end)
  end

  def handle_event("skip_dose", %{"id" => id}, socket) do
    with_dose(socket, id, fn dose ->
      Medications.mark_dose_skipped(socket.assigns.current_scope.user, socket.assigns.pet, dose)
    end)
  end

  def handle_event("toggle_active", %{"id" => id, "active" => active}, socket) do
    with_schedule(socket, id, fn schedule ->
      Medications.set_active(
        socket.assigns.current_scope.user,
        socket.assigns.pet,
        schedule,
        active == "true"
      )
    end)
  end

  def handle_event("delete_schedule", %{"id" => id}, socket) do
    with_schedule(socket, id, fn schedule ->
      Medications.delete_schedule(
        socket.assigns.current_scope.user,
        socket.assigns.pet,
        schedule
      )
    end)
  end

  # A dose/schedule change from this or another caretaker refreshes the live checklist.
  @impl true
  def handle_info({:dose_updated, _dose}, socket), do: {:noreply, load(socket)}
  def handle_info({:entry_created, _entry}, socket), do: {:noreply, load(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp with_dose(socket, id, fun) do
    dose = Enum.find(socket.assigns.doses, &(to_string(&1.id) == id))

    case dose && fun.(dose) do
      {:ok, _} ->
        {:noreply, load(socket)}

      {:error, :already_recorded} ->
        {:noreply, socket |> put_flash(:info, gettext("Already recorded.")) |> load()}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, gettext("Not allowed."))}

      _ ->
        {:noreply, socket}
    end
  end

  defp with_schedule(socket, id, fun) do
    schedule = Enum.find(socket.assigns.schedules, &(to_string(&1.id) == id))

    case schedule && fun.(schedule) do
      {:ok, _} -> {:noreply, load(socket)}
      {:error, :unauthorized} -> {:noreply, put_flash(socket, :error, gettext("Not allowed."))}
      _ -> {:noreply, socket}
    end
  end

  # Parse a "08:00, 20:00" free-text field into a sorted, unique list of Times.
  defp parse_times(nil), do: :error

  defp parse_times(str) do
    parsed =
      str
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&parse_time/1)

    if parsed != [] and Enum.all?(parsed, &match?({:ok, _}, &1)) do
      {:ok, parsed |> Enum.map(fn {:ok, t} -> t end) |> Enum.uniq() |> Enum.sort()}
    else
      :error
    end
  end

  defp parse_time(s) do
    s = if String.length(s) == 5, do: s <> ":00", else: s
    Time.from_iso8601(s)
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
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      unread_notifications={@unread_notifications}
      unread_messages={@unread_messages}
    >
      <section id="medications" aria-labelledby="medications-heading" class="mx-auto max-w-2xl">
        <div class="flex items-center gap-2">
          <.link
            navigate={~p"/pets/#{@pet.id}"}
            id="medications-back"
            class="btn btn-ghost btn-sm btn-circle"
            aria-label={gettext("Back")}
          >
            <.icon name="hero-arrow-left" class="size-4" />
          </.link>
          <h1 id="medications-heading" class="text-2xl font-semibold">
            {gettext("Medications for %{name}", name: @pet.name)}
          </h1>
        </div>

        <p :if={@error} id="medications-error" class="text-error mt-2 text-sm" aria-live="polite">
          {@error}
        </p>

        <%!-- Doses due — the coordination checklist. --%>
        <section id="doses-due" aria-labelledby="doses-heading" class="mt-6">
          <h2 id="doses-heading" class="text-lg font-semibold">{gettext("Doses due")}</h2>

          <p :if={@doses == []} class="text-base-content/60 mt-1 text-sm">
            {gettext("No upcoming doses.")}
          </p>

          <ul class="mt-2 space-y-2">
            <li
              :for={dose <- @doses}
              id={"dose-#{dose.id}"}
              class="card card-border bg-base-100 flex flex-row items-center justify-between gap-3 p-3"
            >
              <div>
                <p class="dose-title font-medium">
                  {dose.schedule.medication_name} · {dose.schedule.dose}
                </p>
                <p class="text-base-content/60 text-xs">
                  <time datetime={DateTime.to_iso8601(dose.due_at)}>{format_datetime(dose.due_at)}</time>
                  · <span class="dose-status">{dose_status_label(dose.status)}</span>
                </p>
              </div>

              <div :if={dose.status == "pending" and @can_write?} class="flex gap-2">
                <button
                  type="button"
                  id={"dose-give-#{dose.id}"}
                  phx-click="give_dose"
                  phx-value-id={dose.id}
                  class="btn btn-primary btn-sm"
                >
                  {gettext("Give")}
                </button>
                <button
                  type="button"
                  id={"dose-skip-#{dose.id}"}
                  phx-click="skip_dose"
                  phx-value-id={dose.id}
                  class="btn btn-ghost btn-sm"
                >
                  {gettext("Skip")}
                </button>
              </div>
            </li>
          </ul>
        </section>

        <%!-- Schedules. --%>
        <section id="schedules" aria-labelledby="schedules-heading" class="mt-8">
          <h2 id="schedules-heading" class="text-lg font-semibold">{gettext("Schedules")}</h2>

          <ul class="mt-2 space-y-2">
            <li
              :for={schedule <- @schedules}
              id={"schedule-#{schedule.id}"}
              class="card card-border bg-base-100 flex flex-row items-center justify-between gap-3 p-3"
            >
              <div>
                <p class="schedule-title font-medium">
                  {schedule.medication_name} · {schedule.dose}
                  <span :if={not schedule.active} class="badge badge-ghost badge-sm ml-1">
                    {gettext("Paused")}
                  </span>
                </p>
                <p class="text-base-content/60 text-xs">
                  {times_label(schedule.times_of_day)} · {schedule.timezone}
                </p>
              </div>

              <div :if={@can_write?} class="flex gap-2">
                <button
                  type="button"
                  id={"schedule-toggle-#{schedule.id}"}
                  phx-click="toggle_active"
                  phx-value-id={schedule.id}
                  phx-value-active={to_string(not schedule.active)}
                  class="btn btn-ghost btn-sm"
                >
                  {if schedule.active, do: gettext("Pause"), else: gettext("Resume")}
                </button>
                <button
                  :if={@can_manage?}
                  type="button"
                  id={"schedule-delete-#{schedule.id}"}
                  phx-click="delete_schedule"
                  phx-value-id={schedule.id}
                  data-confirm={gettext("Delete this schedule and its upcoming doses?")}
                  class="btn btn-ghost btn-sm text-error"
                >
                  {gettext("Delete")}
                </button>
              </div>
            </li>
          </ul>

          <%!-- Create form (write-gated). --%>
          <.form
            :if={@can_write?}
            for={@schedule_form}
            id="schedule-form"
            phx-submit="save_schedule"
            class="mt-4 space-y-2"
          >
            <h3 class="font-medium">{gettext("Add a schedule")}</h3>
            <.input
              field={@schedule_form[:medication_name]}
              type="text"
              label={gettext("Medication")}
              required
            />
            <.input field={@schedule_form[:dose]} type="text" label={gettext("Dose")} required />
            <.input
              field={@schedule_form[:times]}
              type="text"
              label={gettext("Dose times")}
              placeholder="08:00, 20:00"
              required
            />
            <.input
              field={@schedule_form[:interval_days]}
              type="number"
              label={gettext("Every N days")}
              min="1"
            />
            <.input
              field={@schedule_form[:start_date]}
              type="date"
              label={gettext("Start date")}
              required
            />
            <.input
              field={@schedule_form[:end_date]}
              type="date"
              label={gettext("End date (optional)")}
            />
            <.input
              field={@schedule_form[:timezone]}
              type="select"
              label={gettext("Timezone")}
              value={@timezone}
              options={Goodmao2.Timezone.all()}
            />
            <.input field={@schedule_form[:notes]} type="textarea" label={gettext("Notes")} />
            <.button variant="primary" phx-disable-with={gettext("Saving...")}>
              {gettext("Add schedule")}
            </.button>
          </.form>
        </section>
      </section>
    </Layouts.app>
    """
  end

  defp dose_status_label("pending"), do: gettext("Pending")
  defp dose_status_label("given"), do: gettext("Given")
  defp dose_status_label("skipped"), do: gettext("Skipped")
  defp dose_status_label("missed"), do: gettext("Missed")
  defp dose_status_label(other), do: other

  defp times_label(times) do
    times |> Enum.map(&Calendar.strftime(&1, "%H:%M")) |> Enum.join(", ")
  end
end
