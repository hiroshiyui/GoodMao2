defmodule Goodmao2Web.PetLive.LogEntry do
  @moduledoc """
  A single log entry: edit it (if you may) and read its full revision history (ADR-0009).

  The edit form is shown only to callers who can modify the entry, and disappears behind a
  notice once the entry hits its nine-edit cap. The revision history follows the entry's read
  authorization — any reader who can see the entry can see how it changed — so it renders for
  everyone, not just editors.
  """
  use Goodmao2Web, :live_view

  alias Goodmao2.{Accounts, Logs, Pets}
  alias Goodmao2.Logs.LogEntry

  @impl true
  def mount(%{"pet_id" => pet_id, "id" => id}, _session, socket) do
    user = socket.assigns.current_scope.user

    with {:ok, pet} <- Pets.fetch_pet(user, pet_id),
         entry when not is_nil(entry) <- Logs.get_entry(user, pet, id) do
      role = Pets.effective_role(pet, user)

      {:ok,
       socket
       |> assign(:pet, pet)
       |> assign(:role, role)
       |> assign(:page_title, gettext("%{type} entry", type: log_type_label(entry.type)))
       |> load_entry(entry)}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Entry not found."))
         |> push_navigate(to: ~p"/pets/#{pet_id}")}
    end
  end

  # (Re)load everything derived from the entry: the edit form, the cap state, and the
  # revision history with its editors' labels.
  defp load_entry(socket, entry) do
    user = socket.assigns.current_scope.user
    pet = socket.assigns.pet
    revisions = Logs.list_revisions(user, pet, entry)
    editors = Accounts.get_users_map(Enum.map(revisions, & &1.edited_by_user_id))

    socket
    |> assign(:entry, entry)
    |> assign(:can_edit?, Logs.can_edit?(user, pet, entry))
    |> assign(:at_limit?, entry.edit_count >= Logs.max_edits())
    |> assign(:revisions, revisions)
    |> assign(:editors, editors)
    |> assign(:form, to_form(entry_params(entry), as: :log))
    |> assign(:error, nil)
  end

  # Flatten the entry into form params: its structured `data` plus the shared note / time /
  # visibility fields (time in the datetime-local input's shape).
  defp entry_params(entry) do
    Map.merge(entry.data || %{}, %{
      "note" => entry.note,
      "occurred_at" =>
        entry.occurred_at && Calendar.strftime(entry.occurred_at, "%Y-%m-%dT%H:%M"),
      "visibility" => entry.visibility
    })
  end

  @impl true
  def handle_event("validate", %{"log" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :log))}
  end

  def handle_event("save", %{"log" => params}, socket) do
    user = socket.assigns.current_scope.user
    pet = socket.assigns.pet
    entry = socket.assigns.entry

    {note, params} = Map.pop(params, "note")
    {occurred_at, params} = Map.pop(params, "occurred_at")
    {visibility, data} = Map.pop(params, "visibility")

    attrs =
      %{"data" => data, "note" => blank_to_nil(note)}
      |> maybe_put("occurred_at", blank_to_nil(occurred_at))
      |> maybe_put("visibility", visibility)

    case Logs.update_entry(user, pet, entry, attrs) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Changes saved."))
         |> load_entry(updated)}

      {:error, :edit_limit} ->
        {:noreply,
         put_flash(socket, :error, gettext("This entry has reached its nine-edit limit."))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to edit this entry."))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :error, changeset_error_message(changeset))}
    end
  end

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

  defp editor_label(editors, user_id) do
    case Map.get(editors, user_id) do
      nil -> gettext("a former caretaker")
      user -> Layouts.account_label(user)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        <.link
          navigate={~p"/pets/#{@pet.id}"}
          id="log-back"
          class="btn btn-ghost btn-sm btn-circle align-middle"
          aria-label={gettext("Back to %{name}", name: @pet.name)}
        >
          <.icon name="hero-arrow-left" class="size-4" />
        </.link>
        {log_type_label(@entry.type)}
        <:subtitle>{@pet.name}</:subtitle>
      </.header>

      <section
        id="log-entry-card"
        aria-labelledby="log-entry-heading"
        class="card card-border bg-base-100 mt-4"
      >
        <div class="card-body p-4">
          <h2 id="log-entry-heading" class="sr-only">{gettext("Current entry")}</h2>
          <p class="log-entry-summary break-words">{log_summary(@entry)}</p>
          <p :if={@entry.note} class="log-entry-note text-base-content/70 text-sm break-words">
            {@entry.note}
          </p>
          <p class="text-base-content/50 flex flex-wrap items-center gap-2 text-xs">
            <time datetime={DateTime.to_iso8601(@entry.occurred_at)}>
              {format_datetime(@entry.occurred_at)}
            </time>
            <span class="badge badge-ghost badge-xs">{translate_visibility(@entry.visibility)}</span>
            <span :if={@entry.edit_count > 0} id="log-edit-count" class="badge badge-ghost badge-xs">
              {gettext("Edited %{n} of %{max}", n: @entry.edit_count, max: Logs.max_edits())}
            </span>
          </p>
        </div>
      </section>

      <section
        :if={@can_edit? and not @at_limit?}
        id="log-edit-section"
        aria-labelledby="log-edit-heading"
        class="mt-6"
      >
        <h2 id="log-edit-heading" class="text-lg font-semibold">{gettext("Edit entry")}</h2>
        <p class="text-base-content/60 text-sm">
          {gettext("Each saved change keeps a snapshot. %{left} edits left.",
            left: Logs.max_edits() - @entry.edit_count
          )}
        </p>

        <p :if={@error} id="log-edit-error" role="alert" class="text-error mt-3 text-sm">{@error}</p>

        <.form
          for={@form}
          id="log-edit-form"
          phx-change="validate"
          phx-submit="save"
          class="mt-3 space-y-3"
        >
          <.log_fields type={@entry.type} form={@form} />

          <.input
            :if={@entry.type != "life"}
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

          <div class="flex gap-2">
            <.button
              type="submit"
              id="log-edit-submit"
              class="btn btn-primary"
              phx-disable-with={gettext("Saving…")}
            >
              {gettext("Save changes")}
            </.button>
            <.link navigate={~p"/pets/#{@pet.id}"} id="log-edit-cancel" class="btn btn-ghost">
              {gettext("Cancel")}
            </.link>
          </div>
        </.form>
      </section>

      <div
        :if={@can_edit? and @at_limit?}
        id="log-edit-limit-notice"
        role="status"
        class="alert alert-warning mt-6"
      >
        <.icon name="hero-lock-closed" class="size-5" />
        <span>
          {gettext("This entry has reached its nine-edit limit and can no longer be changed.")}
        </span>
      </div>

      <section id="log-history-section" aria-labelledby="log-history-heading" class="mt-6">
        <h2 id="log-history-heading" class="text-lg font-semibold">{gettext("Edit history")}</h2>
        <p :if={@revisions == []} id="log-history-empty" class="text-base-content/60 mt-2 text-sm">
          {gettext("No edits yet — this entry is as first recorded.")}
        </p>
        <ol :if={@revisions != []} id="log-history" class="mt-3 space-y-2">
          <li
            :for={rev <- @revisions}
            id={"log-revision-#{rev.id}"}
            class="log-revision card card-border bg-base-100"
          >
            <div class="card-body gap-1 p-3">
              <p class="text-base-content/50 flex flex-wrap items-center gap-2 text-xs">
                <span class="log-revision-editor">{editor_label(@editors, rev.edited_by_user_id)}</span>
                <span aria-hidden="true">·</span>
                <time datetime={DateTime.to_iso8601(rev.inserted_at)}>
                  {format_datetime(rev.inserted_at)}
                </time>
              </p>
              <p class="text-base-content/50 text-xs">{gettext("Previous value:")}</p>
              <p class="log-revision-summary text-sm break-words">
                {log_summary(%{type: rev.snapshot["type"], data: rev.snapshot["data"] || %{}})}
              </p>
              <p
                :if={rev.snapshot["note"]}
                class="log-revision-note text-base-content/70 text-sm break-words"
              >
                {rev.snapshot["note"]}
              </p>
            </div>
          </li>
        </ol>
      </section>
    </Layouts.app>
    """
  end
end
