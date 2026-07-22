defmodule Goodmao2.Media.Avatars do
  @moduledoc """
  Profile images (avatars) for users and pets (ADR-0020).

  Reuses the log-agnostic media primitives — `Media.Purifier` (EXIF/GPS strip, alpha-flatten,
  re-encode), `Media.Storage` staging, and `Media.Limits` — but stores one purified image per
  owner in the dedicated `avatars` keyspace, off the request path:

    * `set_avatar/4` authorizes the caller, upserts the owner's `avatars` row to `processing`,
      and enqueues an `AvatarPurifyWorker` in the same transaction (mirroring `Media.create_life_log/4`).
    * the worker purifies the staged bytes and calls `attach_purified_avatar/2`, which stores the
      clean object and flips the row to `ready`, then broadcasts so open views refresh.

  **Authorization.** Setting a *user* avatar is self-only; setting a *pet* avatar needs `:manage`
  (like `Pets.update_pet`). Viewing a *user* avatar is allowed to any authenticated user (users are
  visible across messaging/notifications); viewing a *pet* avatar needs `:read` on the pet, and an
  avatar the caller can't read is existence-hidden — indistinguishable from one that doesn't exist.
  Avatars are **images only**; a video that slips past the client filter is a classified failure.
  """
  import Ecto.Query, warn: false
  alias Ecto.Multi
  alias Goodmao2.{Logs, Pets, Repo}
  alias Goodmao2.Accounts.User
  alias Goodmao2.Media.{Avatar, AvatarPurifyWorker, Storage}

  @owner_types ~w(user pet)

  @doc "The storage/serving key for an owner (`\"pet-7\"`) — server-derived, never from input."
  def owner_key(owner_type, owner_id) when owner_type in @owner_types,
    do: "#{owner_type}-#{owner_id}"

  @doc "The cache-busting version for an avatar (its `updated_at` as a unix timestamp)."
  def version(%Avatar{updated_at: nil}), do: 0
  def version(%Avatar{updated_at: at}), do: DateTime.to_unix(at)
  def version(_), do: 0

  @doc """
  Claims `owner`'s avatar slot for a staged upload and schedules async purification (ADR-0020).

  `staged_token` comes from `Media.stage_upload/1` (raw bytes already on disk). Authorizes the
  caller (self for a user, `:manage` for a pet), upserts the row to `processing`, and enqueues the
  purify worker transactionally, so either both land or neither does. Returns `{:ok, avatar}` or
  `{:error, :unauthorized}` / a changeset / a reason.
  """
  def set_avatar(owner_type, owner_id, %User{} = actor, staged_token, crop \\ nil)
      when owner_type in @owner_types and is_binary(staged_token) do
    with :ok <- authorize_set(owner_type, owner_id, actor) do
      upsert_and_enqueue(owner_type, owner_id, actor, staged_token, sanitize_crop(crop))
    end
  end

  # A square crop is advisory from the client (ADR-0020): keep only well-formed normalized
  # fractions here, and the purifier re-validates/clamps again before applying. Anything else ⇒
  # nil (full frame). Accepts the `%{"x"=>, …}` params map straight from the form.
  defp sanitize_crop(%{"x" => x, "y" => y, "w" => w, "h" => h}) do
    with {xf, _} <- to_float(x),
         {yf, _} <- to_float(y),
         {wf, _} <- to_float(w),
         {hf, _} <- to_float(h),
         true <-
           xf >= 0 and yf >= 0 and wf > 0 and hf > 0 and xf + wf <= 1.001 and yf + hf <= 1.001 do
      %{"x" => xf, "y" => yf, "w" => wf, "h" => hf}
    else
      _ -> nil
    end
  end

  defp sanitize_crop(_), do: nil

  defp to_float(n) when is_number(n), do: {n * 1.0, ""}
  defp to_float(s) when is_binary(s), do: Float.parse(s)
  defp to_float(_), do: :error

  defp upsert_and_enqueue(owner_type, owner_id, actor, staged_token, crop) do
    changeset =
      Avatar.upsert_changeset(%Avatar{}, %{
        "owner_type" => owner_type,
        "owner_id" => owner_id,
        "status" => "processing",
        "uploaded_by_user_id" => actor.id
      })

    Multi.new()
    # Re-claim the slot: a repeated upload for the same owner reprocesses the one row (the old
    # object stays served until the new one overwrites it). `updated_at` is always bumped.
    |> Multi.insert(:avatar, changeset,
      on_conflict: {:replace, [:status, :uploaded_by_user_id, :updated_at]},
      conflict_target: [:owner_type, :owner_id]
    )
    |> Multi.run(:enqueue, fn _repo, %{avatar: avatar} ->
      Oban.insert(
        AvatarPurifyWorker.new(%{
          "avatar_id" => avatar.id,
          "token" => staged_token,
          "crop" => crop
        })
      )
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{avatar: avatar}} -> {:ok, avatar}
      {:error, _step, %Ecto.Changeset{} = changeset, _} -> {:error, changeset}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  @doc """
  Attaches an **already-purified** image to its avatar row (ADR-0020) — the worker's landing step.

  Stores the clean bytes under the owner key and flips the row to `ready` with the object's
  metadata; if the byte write fails the row update rolls back so Oban can retry. Re-broadcasts on
  success. Returns `{:ok, avatar}` or `{:error, reason}`.
  """
  def attach_purified_avatar(avatar_id, purified) do
    case Repo.get(Avatar, avatar_id) do
      %Avatar{} = avatar ->
        key = owner_key(avatar.owner_type, avatar.owner_id)

        ready =
          Avatar.ready_changeset(avatar, %{
            "content_type" => purified.content_type,
            "byte_size" => purified.byte_size
          })

        Multi.new()
        |> Multi.update(:avatar, ready)
        |> Multi.run(:store, fn _repo, _ ->
          case Storage.store_avatar(key, purified.path) do
            :ok -> {:ok, key}
            {:error, reason} -> {:error, reason}
          end
        end)
        |> Repo.transaction()
        |> case do
          {:ok, %{avatar: avatar}} ->
            broadcast(avatar)
            {:ok, avatar}

          {:error, _step, reason, _} ->
            {:error, reason}
        end

      nil ->
        {:error, :not_found}
    end
  end

  @doc """
  Resolves a failed purification (ADR-0020): keep a previously-served object (revert to `ready`)
  or, for a first-ever upload with no object yet, drop the row so views fall back cleanly. Either
  way, re-broadcast so open views refresh.
  """
  def mark_failed(avatar_id) do
    case Repo.get(Avatar, avatar_id) do
      %Avatar{} = avatar ->
        key = owner_key(avatar.owner_type, avatar.owner_id)

        avatar =
          if Storage.avatar_exists?(key) do
            avatar |> Ecto.Changeset.change(status: "ready") |> Repo.update!()
          else
            Repo.delete!(avatar)
            %{avatar | status: "failed"}
          end

        broadcast(avatar)
        :ok

      nil ->
        :ok
    end
  end

  @doc "The avatar row by its own id, or `nil` (used by the purify worker)."
  def get_avatar_by_id(id), do: Repo.get(Avatar, id)

  @doc "The avatar row for an owner, or `nil`."
  def get_avatar(owner_type, owner_id) when owner_type in @owner_types do
    Repo.one(from a in Avatar, where: a.owner_type == ^owner_type and a.owner_id == ^owner_id)
  end

  @doc "Render metadata for one owner — `%{status, version}` or `nil` (no avatar yet)."
  def meta(owner_type, owner_id) when owner_type in @owner_types do
    case get_avatar(owner_type, owner_id) do
      %Avatar{status: status} = avatar -> %{status: status, version: version(avatar)}
      nil -> nil
    end
  end

  @doc """
  Batch metadata for many owners of one type — `%{owner_id => %{status, version}}` — so list
  views (pet cards, message threads) render avatars without an N+1.
  """
  def metas_for(owner_type, ids) when owner_type in @owner_types and is_list(ids) do
    from(a in Avatar, where: a.owner_type == ^owner_type and a.owner_id in ^ids)
    |> Repo.all()
    |> Map.new(fn a -> {a.owner_id, %{status: a.status, version: version(a)}} end)
  end

  @doc """
  Fetches a servable avatar object the caller may view, or `{:error, :not_found}` (ADR-0020).

  Returns `{:ok, {content_type, path}}` only when the owner has an avatar whose bytes are present
  and the caller is authorized (any authenticated user for a user avatar; `:read` on the pet for a
  pet avatar). Existence-hidden: an avatar the caller can't read looks like none at all.
  """
  def fetch_avatar_object_for_user(owner_type, owner_id, %User{} = actor)
      when owner_type in @owner_types do
    with :ok <- authorize_view(owner_type, owner_id, actor),
         %Avatar{content_type: ct} when is_binary(ct) <- get_avatar(owner_type, owner_id),
         key = owner_key(owner_type, owner_id),
         true <- Storage.avatar_exists?(key) do
      {:ok, {ct, Storage.avatar_object_path(key)}}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Removes an owner's avatar (row + bytes). Same authorization as setting it."
  def delete_avatar(owner_type, owner_id, %User{} = actor) when owner_type in @owner_types do
    with :ok <- authorize_set(owner_type, owner_id, actor) do
      key = owner_key(owner_type, owner_id)

      case get_avatar(owner_type, owner_id) do
        %Avatar{} = avatar ->
          Repo.delete!(avatar)
          Storage.delete_avatar(key)
          broadcast(%{avatar | status: "failed"})
          :ok

        nil ->
          :ok
      end
    end
  end

  ## PubSub — a pet avatar rides the pet's timeline topic; a user avatar has its own topic.

  @doc "Subscribes to a user's avatar changes (used by `/users/settings`)."
  def subscribe_user(user_id),
    do: Phoenix.PubSub.subscribe(Goodmao2.PubSub, user_topic(user_id))

  defp user_topic(user_id), do: "avatar:user:#{user_id}"

  defp broadcast(%{owner_type: "pet", owner_id: id} = avatar) do
    Phoenix.PubSub.broadcast(
      Goodmao2.PubSub,
      Logs.topic(id),
      {:avatar_updated, "pet", id, avatar_meta(avatar)}
    )
  end

  defp broadcast(%{owner_type: "user", owner_id: id} = avatar) do
    Phoenix.PubSub.broadcast(
      Goodmao2.PubSub,
      user_topic(id),
      {:avatar_updated, "user", id, avatar_meta(avatar)}
    )
  end

  defp avatar_meta(avatar), do: %{status: avatar.status, version: version(avatar)}

  ## Authorization

  defp authorize_set("user", owner_id, %User{id: id}) do
    if owner_id == id, do: :ok, else: {:error, :unauthorized}
  end

  defp authorize_set("pet", owner_id, %User{} = actor) do
    case Pets.fetch_pet(actor, owner_id, require: :manage) do
      {:ok, _pet} -> :ok
      {:error, _} -> {:error, :unauthorized}
    end
  end

  defp authorize_view("user", _owner_id, %User{}), do: :ok

  defp authorize_view("pet", owner_id, %User{} = actor) do
    case Pets.fetch_pet(actor, owner_id, require: :read) do
      {:ok, _pet} -> :ok
      {:error, _} -> {:error, :not_found}
    end
  end
end
