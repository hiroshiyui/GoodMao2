defmodule Goodmao2.Media do
  @moduledoc """
  The Media context: purified photos/videos attached to `life` log entries (ADR-0005).

  Uploads are actively purified (`Purifier`), stored as opaque objects keyed by id
  (`Storage`), and served only through an authorized, IDOR-hidden endpoint that re-applies
  the parent log's read authorization. Byte and pixel limits are admin-configurable through
  `Media.Limits`; `Media.Avatars` reuses these same primitives for profile images.

  Purification runs **off the request path**: `create_life_log/4` stages the raw upload and
  commits the entry together with one `PurifyWorker` job per file, in one transaction — so
  an entry always gets its jobs and a rolled-back entry leaves none. The `media_assets` row
  is inserted by the worker once clean bytes exist, then re-broadcast so the media appears
  live. **A `life` entry with no media yet is therefore a normal intermediate state**, not a
  broken write; a classified failure sends the uploader a `media_failed` bell instead.
  `OrphanJanitor` reclaims stray objects and stale staged uploads on a daily cron.
  """
  import Ecto.Query, warn: false
  alias Ecto.Multi
  alias Goodmao2.{Logs, Pets, Repo}
  alias Goodmao2.Accounts.User
  alias Goodmao2.Pets.Pet
  alias Goodmao2.Logs.LogEntry
  alias Goodmao2.Media.{MediaAsset, Purifier, PurifyWorker, RateLimiter, Storage}

  @doc "The media config value for `key` (limits, storage_dir, …)."
  def config(key), do: Application.fetch_env!(:goodmao2, __MODULE__)[key]

  @doc "Purifies one uploaded file (`opts[:crop]` optional, avatars). See `Goodmao2.Media.Purifier`."
  defdelegate purify(source_path, opts \\ []), to: Purifier

  @doc "Copies a raw upload into staging, returning `{:ok, token}`. See `Goodmao2.Media.Storage`."
  defdelegate stage_upload(source_path), to: Storage, as: :stage

  @doc "Discards a staged upload by token (cleanup when the log fails to create)."
  defdelegate unstage_upload(token), to: Storage, as: :unstage

  @doc """
  Creates a `life` log entry and schedules its uploaded media for **async** purification (ADR-0005).

  `staged` is a list of `%{token, caption}` from `stage_upload/1` (raw bytes already on disk).
  Requires `:write` on the pet, the pet's history not hidden, and the caller under their hourly
  upload cap; only owners may publish a `public` entry. In one transaction the log row is inserted
  and one `PurifyWorker` job is enqueued per staged file, so either the whole thing lands or none
  of it does. The entry is broadcast (with no media yet); each `PurifyWorker` purifies its file
  off the request path, attaches the ready media row, and re-broadcasts so it appears live.
  """
  def create_life_log(%User{} = user, %Pet{} = pet, attrs, staged) when is_list(staged) do
    cond do
      Pets.history_hidden?(pet) ->
        {:error, :unauthorized}

      not Pets.can?(pet, user, :write) ->
        {:error, :unauthorized}

      # Only owners may publish (mint a public share link), matching Logs.create_entry (ADR-0004).
      attrs["visibility"] == "public" and Pets.effective_role(pet, user) != "owner" ->
        {:error, :unauthorized}

      RateLimiter.check(user.id) == {:error, :rate_limited} ->
        {:error, :rate_limited}

      true ->
        do_create(user, pet, attrs, staged)
    end
  end

  defp do_create(user, pet, attrs, staged) do
    log_attrs = %{
      "pet_id" => pet.id,
      "type" => "life",
      "note" => attrs["note"],
      "visibility" => attrs["visibility"] || "limited",
      "occurred_at" => attrs["occurred_at"]
    }

    log_changeset =
      %LogEntry{recorded_by_user_id: user.id}
      |> LogEntry.changeset(log_attrs)
      # Mint/clear the share token in lockstep with visibility, like the timeline (ADR-0004).
      |> Logs.put_share_token()

    multi =
      staged
      |> Enum.with_index()
      |> Enum.reduce(Multi.insert(Multi.new(), :log, log_changeset), fn {s, i}, m ->
        # Transactional enqueue: the purify job lands iff the log row commits (Oban shares the repo).
        Multi.run(m, {:purify, i}, fn _repo, %{log: log} ->
          Oban.insert(
            PurifyWorker.new(%{
              "token" => s.token,
              "log_entry_id" => log.id,
              "pet_id" => pet.id,
              "uploaded_by_user_id" => user.id,
              "caption" => s[:caption]
            })
          )
        end)
      end)

    case Repo.transaction(multi) do
      {:ok, %{log: log}} ->
        entry = Repo.preload(log, media_assets: media_query())
        Phoenix.PubSub.broadcast(Goodmao2.PubSub, Logs.topic(pet), {:entry_created, entry})
        Goodmao2.Notifications.enqueue_log_fanout(pet.id, entry.id)
        {:ok, entry}

      {:error, _step, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, changeset}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc """
  Attaches more uploaded media to an **existing** `life` entry — the ADR-0005 follow-up, used by
  the single-entry page to add or re-upload files after creation.

  `staged` is a list of `%{token, caption}` from `stage_upload/1`, exactly as in
  `create_life_log/4`, and rides the same pipeline: one transactional `PurifyWorker` job per
  file, each attaching its ready row and re-broadcasting. Requires the same right as editing
  the entry (`Logs.can_edit?/3` — so a live, visible entry and `:write`), the caller under the
  hourly upload cap, and room under the per-entry media cap (existing + new). Adding media is
  **not** an edit — it snapshots no revision and does not count against the nine-edit limit.
  """
  def add_media_to_life_log(%User{} = user, %Pet{} = pet, %LogEntry{} = entry, staged)
      when is_list(staged) do
    cond do
      entry.type != "life" or entry.pet_id != pet.id or not is_nil(entry.deleted_at) ->
        {:error, :unauthorized}

      not Logs.can_edit?(user, pet, entry) ->
        {:error, :unauthorized}

      staged == [] ->
        {:error, :no_files}

      media_count(entry.id) + length(staged) > config(:max_entries) ->
        {:error, :media_limit}

      RateLimiter.check(user.id) == {:error, :rate_limited} ->
        {:error, :rate_limited}

      true ->
        enqueue_purify_jobs(user, entry, staged)
    end
  end

  defp media_count(log_entry_id) do
    Repo.aggregate(
      from(m in MediaAsset, where: m.log_entry_id == ^log_entry_id and is_nil(m.deleted_at)),
      :count
    )
  end

  # All-or-nothing enqueue, mirroring `do_create/4`: every staged file gets its purify job or
  # none does (no row changes here — the media rows land asynchronously via the workers).
  defp enqueue_purify_jobs(user, entry, staged) do
    multi =
      staged
      |> Enum.with_index()
      |> Enum.reduce(Multi.new(), fn {s, i}, m ->
        Multi.run(m, {:purify, i}, fn _repo, _changes ->
          Oban.insert(
            PurifyWorker.new(%{
              "token" => s.token,
              "log_entry_id" => entry.id,
              "pet_id" => entry.pet_id,
              "uploaded_by_user_id" => user.id,
              "caption" => s[:caption]
            })
          )
        end)
      end)

    case Repo.transaction(multi) do
      {:ok, _} -> :ok
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  Soft-deletes one media asset of a `life` entry (stamps `deleted_at`; the bytes stay, owned by
  the soft-deleted row — ADR-0008). Requires the same right as editing the entry
  (`Logs.can_edit?/3`); the asset must belong to `entry`. Existence is hidden — an asset the
  caller may not touch is `{:error, :not_found}`. Re-broadcasts the entry so live viewers see
  the media disappear.
  """
  def delete_media_asset(%User{} = user, %Pet{} = pet, %LogEntry{} = entry, asset_id) do
    asset =
      Repo.one(
        from m in MediaAsset,
          where: m.id == ^asset_id and m.log_entry_id == ^entry.id and is_nil(m.deleted_at)
      )

    with %MediaAsset{} <- asset,
         true <- entry.pet_id == pet.id and is_nil(entry.deleted_at),
         true <- Logs.can_edit?(user, pet, entry) do
      asset
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now(:second))
      |> Repo.update()
      |> case do
        {:ok, deleted} ->
          broadcast_entry_updated(entry.pet_id, entry.id)
          {:ok, deleted}

        {:error, _} = error ->
          error
      end
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Attaches one **already-purified** media object to its log entry (ADR-0005) — the `PurifyWorker`'s
  landing step. Inserts the ready `media_assets` row and writes the clean bytes; if the write
  fails the row rolls back. On success re-broadcasts the parent entry (media preloaded) so live
  viewers see the new photo/video. Returns `{:ok, asset}` or `{:error, reason}`.
  """
  def attach_purified_asset(%{log_entry_id: log_entry_id, pet_id: pet_id} = params, purified) do
    changeset =
      MediaAsset.changeset(%MediaAsset{}, %{
        "log_entry_id" => log_entry_id,
        "pet_id" => pet_id,
        "uploaded_by_user_id" => params[:uploaded_by_user_id],
        "kind" => purified.kind,
        "content_type" => purified.content_type,
        "byte_size" => purified.byte_size,
        "caption" => params[:caption]
      })

    Multi.new()
    |> Multi.insert(:asset, changeset)
    |> Multi.run(:store, fn _repo, %{asset: asset} ->
      case Storage.store(asset.id, purified.path) do
        :ok -> {:ok, asset.id}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{asset: asset}} ->
        broadcast_entry_updated(pet_id, log_entry_id)
        {:ok, asset}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp broadcast_entry_updated(pet_id, log_entry_id) do
    case Repo.get(LogEntry, log_entry_id) do
      %LogEntry{} = entry ->
        entry = Repo.preload(entry, media_assets: media_query())
        Phoenix.PubSub.broadcast(Goodmao2.PubSub, Logs.topic(pet_id), {:entry_updated, entry})

      _ ->
        :ok
    end
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

  @doc """
  The non-deleted media of a log entry, id-ordered — the preload used when this context
  re-broadcasts an entry. `Logs` keeps its own equivalent for the timeline's own reads.
  """
  def media_query do
    from m in MediaAsset, where: is_nil(m.deleted_at), order_by: m.id
  end

  @default_orphan_age_seconds 3600

  @doc """
  Sweeps storage of orphaned bytes (ADR-0005) — the cron janitor's work.

  Two kinds of orphan, both only possible after a hard crash or a failed/abandoned upload:

    * a **stored object** (`storage_dir/<shard>/<id>`) whose integer id has **no** `media_assets`
      row at all (a soft-deleted row still owns its bytes, so it is not an orphan); and
    * a **staged** raw upload whose `PurifyWorker` never unstaged it.

  Only files older than `age_seconds` (default 1h) are removed, so an in-flight upload or a
  running worker is never raced. Returns `%{objects: n, staged: n}`.
  """
  def delete_orphans(age_seconds \\ @default_orphan_age_seconds) do
    cutoff = System.system_time(:second) - age_seconds
    %{objects: sweep_objects(cutoff), staged: sweep_staged(cutoff)}
  end

  # sobelow_skip ["Traversal.FileModule"]
  # Only reads/deletes files under the configured storage_dir; ids are parsed from filenames and
  # deleted via Storage.delete/1 (id-derived path), never a request string.
  defp sweep_objects(cutoff) do
    root = Storage.storage_dir()

    for shard <- list_dir(root),
        shard =~ ~r/\A\d{3}\z/,
        file <- list_dir(Path.join(root, shard)),
        {id, ""} <- [Integer.parse(file)],
        older_than?(Path.join([root, shard, file]), cutoff),
        not asset_row_exists?(id),
        reduce: 0 do
      n ->
        Storage.delete(id)
        n + 1
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  # Only reads/deletes files directly under the staging root; the filename *is* the token, which
  # Storage.unstage/1 re-validates before touching the filesystem.
  defp sweep_staged(cutoff) do
    root = Storage.staging_root()

    for token <- list_dir(root),
        older_than?(Path.join(root, token), cutoff),
        reduce: 0 do
      n ->
        Storage.unstage(token)
        n + 1
    end
  end

  defp asset_row_exists?(id), do: Repo.exists?(from m in MediaAsset, where: m.id == ^id)

  defp list_dir(path) do
    case File.ls(path) do
      {:ok, entries} -> entries
      {:error, _} -> []
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  # `path` is built from the storage/staging roots plus validated shard/id/token segments above.
  defp older_than?(path, cutoff) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime <= cutoff
      _ -> false
    end
  end
end
