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
    |> assign(
      :form,
      to_form(entry_params(entry, socket.assigns.timezone, pet.weight_unit), as: :log)
    )
    |> assign(:error, nil)
  end

  # Flatten the entry into form params: its structured `data` plus the shared note / time /
  # visibility fields (time shifted into the viewer's timezone — ADR-0018; a weight value shown
  # in the pet's unit — roadmap §8).
  defp entry_params(entry, tz, unit) do
    (entry.data || %{})
    |> weight_grams_to_field(entry.type, unit)
    |> Map.merge(%{
      "note" => entry.note,
      "occurred_at" =>
        entry.occurred_at &&
          entry.occurred_at
          |> Goodmao2.Timezone.to_local(tz)
          |> Calendar.strftime("%Y-%m-%dT%H:%M"),
      "visibility" => entry.visibility
    })
  end

  defp weight_grams_to_field(%{"weight_grams" => g} = data, "weight", unit) do
    data
    |> Map.delete("weight_grams")
    |> Map.put("weight", Goodmao2Web.Helpers.weight_input_value(g, unit))
  end

  defp weight_grams_to_field(data, _type, _unit), do: data

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
      %{
        "data" => weight_field_to_grams(data, entry.type, pet.weight_unit),
        "note" => blank_to_nil(note)
      }
      |> put_local_occurred_at(occurred_at, socket.assigns.timezone)
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

  # Share-link expiry (ADR-0004) — owner-only, only meaningful while the entry is public. The
  # datetime-local wall-clock is interpreted in the viewer's timezone and stored UTC.
  def handle_event("set_share_expiry", %{"expires_at" => value}, socket) do
    case blank_to_nil(value) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Choose an expiry date and time."))}

      str ->
        case Goodmao2.Timezone.local_naive_to_utc(str, socket.assigns.timezone) do
          {:ok, dt} -> apply_share_expiry(socket, dt)
          :error -> {:noreply, put_flash(socket, :error, gettext("That date couldn't be read."))}
        end
    end
  end

  def handle_event("clear_share_expiry", _params, socket) do
    apply_share_expiry(socket, nil)
  end

  defp apply_share_expiry(socket, expires_at) do
    %{current_scope: %{user: user}, pet: pet, entry: entry} = socket.assigns

    case Logs.set_share_expiry(user, pet, entry, expires_at) do
      {:ok, updated} ->
        {:noreply,
         socket |> put_flash(:info, gettext("Share link updated.")) |> load_entry(updated)}

      {:error, :expiry_in_past} ->
        {:noreply, put_flash(socket, :error, gettext("Pick a time in the future."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't update the share link."))}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # The weight field is edited in the pet's unit; store canonical grams (roadmap §8).
  defp weight_field_to_grams(%{"weight" => value} = data, "weight", unit) do
    data
    |> Map.delete("weight")
    |> Map.put("weight_grams", Goodmao2Web.Helpers.weight_to_grams(value, unit))
  end

  defp weight_field_to_grams(data, _type, _unit), do: data

  # Interpret the datetime-local wall-clock in the viewer's timezone and store UTC (ADR-0018);
  # blank omits it (changeset keeps the prior time), unparseable passes through to be rejected.
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

  defp editor_label(editors, user_id) do
    case Map.get(editors, user_id) do
      nil -> gettext("a former caretaker")
      user -> Layouts.account_label(user)
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
          <p class="log-entry-summary break-words">{log_summary(@entry, @pet.weight_unit)}</p>
          <p :if={@entry.note} class="log-entry-note text-base-content/70 text-sm break-words">
            {@entry.note}
          </p>
          <.media_grid
            :if={@entry.media_assets != []}
            assets={@entry.media_assets}
            class="mt-1 flex flex-wrap gap-2"
            media_class="max-h-64"
          />
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
        :if={@role == "owner" and @entry.visibility == "public" and @entry.share_token}
        id="log-share-section"
        aria-labelledby="log-share-heading"
        class="card card-border border-primary/40 bg-base-100 mt-6"
      >
        <div class="card-body gap-3 p-4">
          <div>
            <h2 id="log-share-heading" class="text-lg font-semibold">
              <.icon name="hero-link" class="size-5 align-middle" /> {gettext("Share link")}
            </h2>
            <p class="text-base-content/60 text-sm">
              {gettext(
                "Anyone with this link can view just this entry while it stays public. Set the entry to Limited or Private to revoke it."
              )}
            </p>
          </div>

          <div class="flex flex-wrap items-center gap-2">
            <input
              id="log-share-url"
              type="text"
              readonly
              value={url(~p"/entries/shared/#{@entry.share_token}")}
              class="input input-bordered input-sm min-w-0 flex-1"
              aria-label={gettext("Share link URL")}
            />
            <button
              type="button"
              id="log-share-copy"
              phx-hook="Clipboard"
              data-clipboard-target="#log-share-url"
              class="btn btn-sm btn-primary"
            >
              <.icon name="hero-clipboard-document" class="size-4" /> {gettext("Copy")}
            </button>
          </div>

          <div class="border-base-200 border-t pt-3">
            <p class="text-sm font-medium">{gettext("Expiry")}</p>
            <p id="log-share-expiry-status" class="text-base-content/60 text-sm">
              <%= if @entry.share_expires_at do %>
                {gettext("Expires %{when}", when: format_datetime(@entry.share_expires_at))}
              <% else %>
                {gettext("No expiry — active while public.")}
              <% end %>
            </p>
            <form
              id="log-share-expiry-form"
              phx-submit="set_share_expiry"
              class="mt-2 flex flex-wrap items-end gap-2"
            >
              <label for="log-share-expiry-input" class="sr-only">{gettext("Expiry")}</label>
              <input
                id="log-share-expiry-input"
                name="expires_at"
                type="datetime-local"
                class="input input-bordered input-sm"
              />
              <button type="submit" id="log-share-expiry-set" class="btn btn-sm btn-ghost">
                {gettext("Set expiry")}
              </button>
              <button
                :if={@entry.share_expires_at}
                type="button"
                id="log-share-expiry-clear"
                phx-click="clear_share_expiry"
                class="btn btn-sm btn-ghost"
              >
                {gettext("Clear expiry")}
              </button>
            </form>
          </div>
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
          <.log_fields type={@entry.type} form={@form} weight_unit={@pet.weight_unit} />

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
                {log_summary(
                  %{type: rev.snapshot["type"], data: rev.snapshot["data"] || %{}},
                  @pet.weight_unit
                )}
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
