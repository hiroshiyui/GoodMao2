defmodule Goodmao2.Logs do
  @moduledoc """
  The Logs context: structured log entries and the pet timeline.

  Reads and writes re-check pet-level authorization at this boundary, so the
  context is safe on its own:

    * **Hidden history.** When `pet.history_hidden` is set, the whole timeline is
      existence-hidden — reads return empty/`nil` and writes are refused, for every
      role (the owner un-hides via the pet edit form, not a log action). See
      `Goodmao2.Pets.Pet` and ADR-0003.
    * **Per-entry visibility.** A `private` entry is visible only to effective
      **owners** and the entry's **recorder**; `limited`/`public` are visible to any
      effective grant. See ADR-0004.
    * **Edit/delete scope.** An **owner** may delete any entry; anyone else may
      edit/delete only what they recorded. Editing additionally requires write
      capability for the type (`vet_note` stays vet-only). See ADR-0009.

  Soft-deleted entries (`deleted_at` set) are hidden from all reads.
  """
  import Ecto.Query, warn: false
  alias Ecto.Multi
  alias Goodmao2.Repo
  alias Goodmao2.Accounts.User
  alias Goodmao2.Pets
  alias Goodmao2.Pets.Pet
  alias Goodmao2.Logs.{LogEntry, LogEntryRevision}

  @topic_prefix "pet_timeline:"

  # A log entry may be edited at most nine times ("a cat's nine lives"); the tenth is
  # refused. Denormalized on `log_entries.edit_count` for an O(1) cap check (ADR-0009).
  @max_edits 9

  @doc "The maximum number of edits a single log entry may accrue (ADR-0009)."
  def max_edits, do: @max_edits

  @doc "The PubSub topic carrying a pet's live timeline events."
  def topic(%Pet{id: id}), do: topic(id)
  def topic(pet_id), do: @topic_prefix <> to_string(pet_id)

  @doc "Subscribe the caller to a pet's live timeline events."
  def subscribe(pet_or_id), do: Phoenix.PubSub.subscribe(Goodmao2.PubSub, topic(pet_or_id))

  @doc """
  Lists the pet's log entries the caller may read, newest first.

  Filters soft-deleted entries, `private` entries the caller can't see (ADR-0004),
  and returns `[]` when the pet's history is hidden (ADR-0003).

  Options:

    * `:type` — restrict to a single log type (string), or `nil`/`"all"` for all
    * `:limit` — cap the number of rows (default 200)
    * `:from` / `:to` — inclusive `DateTime` bounds on `occurred_at` (either optional);
      used by the calendar view to fetch just the visible month's entries
  """
  def list_entries(%User{} = user, %Pet{} = pet, opts \\ []) do
    if pet.history_hidden do
      []
    else
      role = Pets.effective_role(pet, user)
      limit = Keyword.get(opts, :limit, 200)

      query =
        from e in LogEntry,
          where: e.pet_id == ^pet.id and is_nil(e.deleted_at),
          order_by: [desc: e.occurred_at, desc: e.id],
          limit: ^limit

      query
      |> filter_by_type(Keyword.get(opts, :type))
      |> filter_by_range(Keyword.get(opts, :from), Keyword.get(opts, :to))
      |> filter_by_visibility(role, user.id)
      |> Repo.all()
    end
  end

  @doc """
  The pet's weight measurements the caller may read, **oldest-first**, as
  `%{at: DateTime, grams: number}`.

  Powers the weight-trend chart. Applies the same hidden-history (ADR-0003) and per-entry
  visibility (ADR-0004) rules as `list_entries/3`; entries whose payload lacks a numeric
  `weight_grams` are skipped. `:limit` caps the number of points (default 200).
  """
  def weight_series(%User{} = user, %Pet{} = pet, opts \\ []) do
    if pet.history_hidden do
      []
    else
      role = Pets.effective_role(pet, user)
      limit = Keyword.get(opts, :limit, 200)

      query =
        from e in LogEntry,
          where: e.pet_id == ^pet.id and e.type == "weight" and is_nil(e.deleted_at),
          order_by: [asc: e.occurred_at, asc: e.id],
          limit: ^limit

      query
      |> filter_by_visibility(role, user.id)
      |> Repo.all()
      |> Enum.flat_map(fn entry ->
        case entry.data["weight_grams"] do
          grams when is_number(grams) -> [%{at: entry.occurred_at, grams: grams}]
          _ -> []
        end
      end)
    end
  end

  defp filter_by_range(query, nil, nil), do: query

  defp filter_by_range(query, %DateTime{} = from, nil),
    do: from(e in query, where: e.occurred_at >= ^from)

  defp filter_by_range(query, nil, %DateTime{} = to),
    do: from(e in query, where: e.occurred_at <= ^to)

  defp filter_by_range(query, %DateTime{} = from, %DateTime{} = to),
    do: from(e in query, where: e.occurred_at >= ^from and e.occurred_at <= ^to)

  defp filter_by_type(query, type) when is_binary(type) and type != "all",
    do: from(e in query, where: e.type == ^type)

  defp filter_by_type(query, _type), do: query

  # Owners see every entry; everyone else is denied `private` entries they didn't record.
  defp filter_by_visibility(query, "owner", _user_id), do: query

  defp filter_by_visibility(query, _role, user_id),
    do: from(e in query, where: e.visibility != "private" or e.recorded_by_user_id == ^user_id)

  @doc """
  Fetches a single live entry the caller may read, or `nil`.

  Returns `nil` for a soft-deleted entry, a `private` entry the caller can't see, or
  any entry when the pet's history is hidden.
  """
  def get_entry(%User{} = user, %Pet{} = pet, id) do
    if pet.history_hidden do
      nil
    else
      role = Pets.effective_role(pet, user)

      entry =
        Repo.one(
          from e in LogEntry,
            where: e.id == ^id and e.pet_id == ^pet.id and is_nil(e.deleted_at)
        )

      if entry && can_view_entry?(entry, user.id, role), do: entry, else: nil
    end
  end

  @doc """
  Returns `true` if a caller with `role` and `user_id` may read `entry`.

  Encodes the ADR-0004 rule: a `private` entry is visible only to owners and its
  recorder; all other scopes are visible to any effective grant. Exposed so the live
  timeline (`PetLive.Show`) can apply the same filter to PubSub-pushed entries.
  """
  def can_view_entry?(%LogEntry{visibility: "private"} = entry, user_id, role),
    do: role == "owner" or entry.recorded_by_user_id == user_id

  def can_view_entry?(%LogEntry{}, _user_id, _role), do: true

  @doc "A blank changeset for the given log type."
  def change_entry(%LogEntry{} = entry \\ %LogEntry{}, attrs \\ %{}) do
    LogEntry.changeset(entry, attrs)
  end

  @doc """
  Creates a log entry for a pet on the caller's behalf.

  Requires the caller to hold `:write` on the pet (vet-note authoring additionally
  requires the vet role) and the pet's history not to be hidden. Broadcasts the new
  entry on the pet's timeline topic.
  """
  def create_entry(%User{} = user, %Pet{} = pet, attrs) do
    role = Pets.effective_role(pet, user)

    with :ok <- ensure_visible(pet),
         :ok <- authorize_write(role, attrs["type"] || attrs[:type]) do
      attrs =
        attrs
        |> stringify()
        |> Map.put("pet_id", pet.id)

      result =
        %LogEntry{recorded_by_user_id: user.id}
        |> LogEntry.changeset(attrs)
        |> Repo.insert()

      case result do
        {:ok, entry} ->
          broadcast(pet, {:entry_created, entry})
          {:ok, entry}

        error ->
          error
      end
    end
  end

  @doc """
  Edits a live entry, recording an immutable revision of its prior state (ADR-0009).

  Requires write capability for the type, that the caller is the entry's recorder or
  an owner, and that the pet's history is not hidden. Only owners may change `visibility`;
  the `type` is immutable on edit.

  A **real** change snapshots the entry's prior state into `log_entry_revisions` and bumps
  `edit_count`, in one transaction. A **no-op** edit records nothing and returns `{:ok,
  entry}` unchanged. The **tenth** edit is refused with `{:error, :edit_limit}`. Broadcasts
  the updated entry.
  """
  def update_entry(%User{} = user, %Pet{} = pet, %LogEntry{} = entry, attrs) do
    role = Pets.effective_role(pet, user)
    # The type is immutable on edit — a food entry stays a food entry (ADR-0009).
    attrs = attrs |> stringify() |> Map.delete("type")

    with :ok <- ensure_visible(pet),
         :ok <- authorize_write(role, entry.type),
         :ok <- authorize_modify(role, user, entry),
         :ok <- authorize_visibility_change(role, entry, attrs) do
      changeset = LogEntry.changeset(entry, attrs)

      cond do
        not changeset.valid? ->
          {:error, %{changeset | action: :update}}

        unchanged?(entry, changeset) ->
          {:ok, entry}

        entry.edit_count >= @max_edits ->
          {:error, :edit_limit}

        true ->
          commit_edit(pet, user, entry, changeset)
      end
    end
  end

  # A real change is one that alters any snapshotted field; the re-sanitized `data` map can
  # differ by identity without differing by value, so compare applied snapshots, not `changes`.
  defp unchanged?(entry, changeset) do
    snapshot(Ecto.Changeset.apply_changes(changeset)) == snapshot(entry)
  end

  # The immutable point-in-time copy stored in a revision (and used for no-op detection).
  # Deliberately excludes the share token — a snapshot must never duplicate a secret.
  defp snapshot(%LogEntry{} = entry) do
    %{
      "type" => entry.type,
      "data" => entry.data || %{},
      "note" => entry.note,
      "occurred_at" => entry.occurred_at && DateTime.to_iso8601(entry.occurred_at),
      "visibility" => entry.visibility
    }
  end

  defp commit_edit(pet, user, entry, changeset) do
    revision = %LogEntryRevision{
      log_entry_id: entry.id,
      pet_id: pet.id,
      edited_by_user_id: user.id,
      snapshot: snapshot(entry)
    }

    changeset = Ecto.Changeset.put_change(changeset, :edit_count, entry.edit_count + 1)

    Multi.new()
    |> Multi.insert(:revision, revision)
    |> Multi.update(:entry, changeset)
    |> Repo.transaction()
    |> case do
      {:ok, %{entry: updated}} ->
        broadcast(pet, {:entry_updated, updated})
        {:ok, updated}

      {:error, :entry, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset}
    end
  end

  @doc """
  Lists an entry's revision snapshots, **newest first**, if the caller may read the entry.

  History follows the entry (ADR-0009): the same read authorization as the entry itself —
  any effective grant, plus the private-entry rule and hidden-history existence-hiding.
  Returns `[]` when the caller can't read the entry.
  """
  def list_revisions(%User{} = user, %Pet{} = pet, %LogEntry{} = entry) do
    role = Pets.effective_role(pet, user)

    if pet.history_hidden or not can_view_entry?(entry, user.id, role) do
      []
    else
      Repo.all(
        from r in LogEntryRevision,
          where: r.log_entry_id == ^entry.id,
          order_by: [desc: r.inserted_at, desc: r.id]
      )
    end
  end

  @doc """
  Returns `true` if the caller may edit `entry` — write capability for its type, recorder
  or owner, and the pet's history not hidden. Mirrors the `update_entry/4` gate so the UI
  can show/hide the edit affordance without attempting a write.
  """
  def can_edit?(%User{} = user, %Pet{} = pet, %LogEntry{} = entry) do
    role = Pets.effective_role(pet, user)

    with :ok <- ensure_visible(pet),
         :ok <- authorize_write(role, entry.type),
         :ok <- authorize_modify(role, user, entry) do
      true
    else
      _ -> false
    end
  end

  @doc """
  Soft-deletes an entry (stamps `deleted_at`).

  An owner may delete any entry; anyone else may delete only what they recorded.
  Refused when the pet's history is hidden.
  """
  def delete_entry(%User{} = user, %Pet{} = pet, %LogEntry{} = entry) do
    role = Pets.effective_role(pet, user)

    with :ok <- ensure_visible(pet),
         :ok <- authorize_modify(role, user, entry) do
      case entry
           |> Ecto.Changeset.change(deleted_at: DateTime.utc_now() |> DateTime.truncate(:second))
           |> Repo.update() do
        {:ok, deleted} ->
          broadcast(pet, {:entry_deleted, deleted})
          {:ok, deleted}

        error ->
          error
      end
    end
  end

  # Hidden history existence-hides the whole timeline (reads *and* writes), for every role.
  defp ensure_visible(%Pet{history_hidden: true}), do: {:error, :unauthorized}
  defp ensure_visible(%Pet{}), do: :ok

  defp authorize_write(role, type) do
    cond do
      role not in ["owner", "co_caretaker", "vet"] -> {:error, :unauthorized}
      # Only vets may author authoritative vet notes.
      type == "vet_note" and role != "vet" -> {:error, :unauthorized}
      true -> :ok
    end
  end

  # Owners may modify any entry; any other effective grant only what it recorded.
  defp authorize_modify("owner", _user, _entry), do: :ok

  defp authorize_modify(role, %User{id: user_id}, %LogEntry{recorded_by_user_id: recorder})
       when not is_nil(role) and user_id == recorder,
       do: :ok

  defp authorize_modify(_role, _user, _entry), do: {:error, :unauthorized}

  defp authorize_visibility_change(role, entry, attrs) do
    new_visibility = attrs["visibility"]

    if new_visibility && new_visibility != entry.visibility && role != "owner" do
      {:error, :unauthorized}
    else
      :ok
    end
  end

  defp broadcast(pet, message) do
    Phoenix.PubSub.broadcast(Goodmao2.PubSub, topic(pet), message)
  end

  # Accepts either string- or atom-keyed attrs from forms / callers.
  defp stringify(attrs) do
    Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  end
end
