defmodule Goodmao2.Logs do
  @moduledoc """
  The Logs context: structured log entries and the pet timeline.

  Every read here assumes the caller's pet-level authorization has already been
  checked by the `Pets` context / LiveView hook. Writes re-check capability so the
  context boundary is safe on its own. Soft-deleted entries (`deleted_at` set) are
  hidden from all reads.
  """
  import Ecto.Query, warn: false
  alias Goodmao2.Repo
  alias Goodmao2.Accounts.User
  alias Goodmao2.Pets
  alias Goodmao2.Pets.Pet
  alias Goodmao2.Logs.LogEntry

  @topic_prefix "pet_timeline:"

  @doc "The PubSub topic carrying a pet's live timeline events."
  def topic(%Pet{id: id}), do: topic(id)
  def topic(pet_id), do: @topic_prefix <> to_string(pet_id)

  @doc "Subscribe the caller to a pet's live timeline events."
  def subscribe(pet_or_id), do: Phoenix.PubSub.subscribe(Goodmao2.PubSub, topic(pet_or_id))

  @doc """
  Lists a pet's live (non-deleted) log entries, newest first.

  Options:

    * `:type` — restrict to a single log type (string), or `nil`/`"all"` for all
    * `:limit` — cap the number of rows (default 200)
  """
  def list_entries(%Pet{id: pet_id}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)

    query =
      from e in LogEntry,
        where: e.pet_id == ^pet_id and is_nil(e.deleted_at),
        order_by: [desc: e.occurred_at, desc: e.id],
        limit: ^limit

    query =
      case Keyword.get(opts, :type) do
        type when is_binary(type) and type != "all" -> from e in query, where: e.type == ^type
        _ -> query
      end

    Repo.all(query)
  end

  @doc "Fetches a single live entry scoped to a pet, or `nil`."
  def get_entry(%Pet{id: pet_id}, id) do
    Repo.one(
      from e in LogEntry,
        where: e.id == ^id and e.pet_id == ^pet_id and is_nil(e.deleted_at)
    )
  end

  @doc "A blank changeset for the given log type."
  def change_entry(%LogEntry{} = entry \\ %LogEntry{}, attrs \\ %{}) do
    LogEntry.changeset(entry, attrs)
  end

  @doc """
  Creates a log entry for a pet on the caller's behalf.

  Requires the caller to hold `:write` on the pet (vet-note authoring additionally
  requires the vet role). Broadcasts the new entry on the pet's timeline topic.
  """
  def create_entry(%User{} = user, %Pet{} = pet, attrs) do
    with :ok <- authorize_write(user, pet, attrs["type"] || attrs[:type]) do
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
  Edits a live entry. Requires `:write`; only owners may change `visibility`.
  Broadcasts the updated entry.
  """
  def update_entry(%User{} = user, %Pet{} = pet, %LogEntry{} = entry, attrs) do
    attrs = stringify(attrs)

    with :ok <- authorize_write(user, pet, entry.type),
         :ok <- authorize_visibility_change(user, pet, entry, attrs) do
      case entry |> LogEntry.changeset(attrs) |> Repo.update() do
        {:ok, updated} ->
          broadcast(pet, {:entry_updated, updated})
          {:ok, updated}

        error ->
          error
      end
    end
  end

  @doc "Soft-deletes an entry (stamps `deleted_at`). Requires `:write`."
  def delete_entry(%User{} = user, %Pet{} = pet, %LogEntry{} = entry) do
    with :ok <- authorize_write(user, pet, entry.type) do
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

  defp authorize_write(user, pet, type) do
    cond do
      not Pets.can?(pet, user, :write) -> {:error, :unauthorized}
      # Only vets may author authoritative vet notes.
      type == "vet_note" and Pets.effective_role(pet, user) != "vet" -> {:error, :unauthorized}
      true -> :ok
    end
  end

  defp authorize_visibility_change(user, pet, entry, attrs) do
    new_visibility = attrs["visibility"]

    if new_visibility && new_visibility != entry.visibility &&
         Pets.effective_role(pet, user) != "owner" do
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
