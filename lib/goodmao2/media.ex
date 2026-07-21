defmodule Goodmao2.Media do
  @moduledoc """
  The Media context: purified photos/videos attached to `life` log entries (ADR-0005).

  Uploads are actively purified (`Purifier`), stored as opaque objects keyed by id
  (`Storage`), created **atomically** with their life-log entry, and served only through an
  authorized, IDOR-hidden endpoint that re-applies the parent log's read authorization.
  """
  import Ecto.Query, warn: false
  alias Ecto.Multi
  alias Goodmao2.{Logs, Pets, Repo}
  alias Goodmao2.Accounts.User
  alias Goodmao2.Pets.Pet
  alias Goodmao2.Logs.LogEntry
  alias Goodmao2.Media.{MediaAsset, Purifier, RateLimiter, Storage}

  @doc "The media config value for `key` (limits, storage_dir, …)."
  def config(key), do: Application.fetch_env!(:goodmao2, __MODULE__)[key]

  @doc "Purifies one uploaded file. See `Goodmao2.Media.Purifier`."
  defdelegate purify(source_path), to: Purifier

  @doc """
  Creates a `life` log entry with its purified media, atomically (ADR-0005).

  `purified` is a list of maps from `purify/1` (`%{kind, content_type, path, byte_size}`).
  Requires `:write` on the pet, the pet's history not hidden, and the caller under their
  hourly upload cap. The log row and all media rows are inserted in one transaction and the
  clean bytes written within it; on any failure the rows roll back and any already-written
  objects are removed (an orphan *object* can only survive a hard crash, never a dangling
  row). Broadcasts the new entry (with media preloaded) on the pet's timeline topic.
  """
  def create_life_log_with_media(%User{} = user, %Pet{} = pet, attrs, purified)
      when is_list(purified) do
    cond do
      pet.history_hidden -> {:error, :unauthorized}
      not Pets.can?(pet, user, :write) -> {:error, :unauthorized}
      RateLimiter.check(user.id) == {:error, :rate_limited} -> {:error, :rate_limited}
      true -> do_create(user, pet, attrs, purified)
    end
  end

  defp do_create(user, pet, attrs, purified) do
    log_attrs = %{
      "pet_id" => pet.id,
      "type" => "life",
      "note" => attrs["note"],
      "visibility" => attrs["visibility"] || "limited",
      "occurred_at" => attrs["occurred_at"]
    }

    multi =
      Multi.new()
      |> Multi.insert(
        :log,
        LogEntry.changeset(%LogEntry{recorded_by_user_id: user.id}, log_attrs)
      )

    multi =
      purified
      |> Enum.with_index()
      |> Enum.reduce(multi, fn {p, i}, m ->
        Multi.insert(m, {:asset, i}, fn %{log: log} -> asset_changeset(log, pet, user, p) end)
      end)

    multi = Multi.run(multi, :store, fn _repo, changes -> store_all(changes, purified) end)

    case Repo.transaction(multi) do
      {:ok, %{log: log}} ->
        entry = Repo.preload(log, media_assets: media_query())
        Phoenix.PubSub.broadcast(Goodmao2.PubSub, Logs.topic(pet), {:entry_created, entry})
        Goodmao2.Notifications.enqueue_log_fanout(pet.id, entry.id)
        {:ok, entry}

      {:error, :store, {written_ids, _reason}, _changes} ->
        Enum.each(written_ids, &Storage.delete/1)
        {:error, :storage_failed}

      {:error, _step, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset}
    end
  end

  defp asset_changeset(log, pet, user, p) do
    MediaAsset.changeset(%MediaAsset{}, %{
      "log_entry_id" => log.id,
      "pet_id" => pet.id,
      "uploaded_by_user_id" => user.id,
      "kind" => p.kind,
      "content_type" => p.content_type,
      "byte_size" => p.byte_size,
      "caption" => Map.get(p, :caption)
    })
  end

  # Write each asset's clean bytes into storage, tracking successes so a mid-batch failure can
  # be compensated (the transaction rolls the rows back; we delete the objects already written).
  defp store_all(changes, purified) do
    purified
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {p, i}, {:ok, written} ->
      asset = Map.fetch!(changes, {:asset, i})

      case Storage.store(asset.id, p.path) do
        :ok -> {:cont, {:ok, [asset.id | written]}}
        {:error, reason} -> {:halt, {:error, {written, reason}}}
      end
    end)
  end

  @doc """
  Fetches a live media asset the caller may read, or `{:error, :not_found}` (ADR-0005).

  Resolves the asset by its own id, then re-applies the parent log's full read authorization
  (pet accessible + ADR-0004 visibility + recorder + hidden-history) via the same context
  functions the timeline uses. Existence is hidden — an asset the caller can't read is
  indistinguishable from one that doesn't exist.
  """
  def fetch_asset_for_user(%User{} = user, id) do
    asset = Repo.one(from m in MediaAsset, where: m.id == ^id and is_nil(m.deleted_at))

    with %MediaAsset{} <- asset,
         {:ok, pet} <- Pets.fetch_pet(user, asset.pet_id),
         entry when not is_nil(entry) <- Logs.get_entry(user, pet, asset.log_entry_id) do
      _ = entry
      {:ok, asset}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "The non-deleted media of a log entry, id-ordered — the preload query used by the timeline."
  def media_query do
    from m in MediaAsset, where: is_nil(m.deleted_at), order_by: m.id
  end
end
