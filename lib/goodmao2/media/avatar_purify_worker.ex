defmodule Goodmao2.Media.AvatarPurifyWorker do
  @moduledoc """
  Purifies one staged avatar upload off the request path and attaches it to its row (ADR-0020).

  Enqueued (transactionally) by `Media.Avatars.set_avatar/4`. It reads the raw bytes from staging,
  runs the ffmpeg purifier, and — on success — stores the clean bytes and flips the avatar row to
  `ready` (`Media.Avatars.attach_purified_avatar/2`), re-broadcasting so open views refresh.

  Failure handling mirrors `Media.PurifyWorker`:

    * **Missing staged file** — already processed (or a retry after success); a no-op `:ok`.
    * **Classified purify failure**, or a **video** (avatars are images only) — terminal: unstage,
      resolve the row (`mark_failed/1`), notify the uploader with an `avatar_failed` bell, and
      return `:ok` so Oban does not retry a file that can never succeed.
    * **Attach/store error** (e.g. a transient disk write) — return `{:error, _}` so Oban retries.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Goodmao2.Media
  alias Goodmao2.Media.{Avatars, Storage}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"avatar_id" => avatar_id, "token" => token} = args}) do
    staged = Storage.staged_path(token)

    if File.exists?(staged) do
      process(staged, token, avatar_id, args["crop"])
    else
      :ok
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  # The only File.rm targets `purified.path` — a temp file the purifier itself just generated,
  # never a user-controlled path. Staged bytes are removed via Storage.unstage/1 (validated token).
  defp process(staged, token, avatar_id, crop) do
    case Media.purify(staged, crop: crop) do
      {:ok, %{kind: "image"} = purified} ->
        result = Avatars.attach_purified_avatar(avatar_id, purified)
        File.rm(purified.path)

        case result do
          {:ok, _avatar} ->
            Storage.unstage(token)
            :ok

          # Transient (e.g. disk) — keep the staged bytes and let Oban retry.
          {:error, reason} ->
            {:error, reason}
        end

      # A video (avatars are images only) or an unpurifiable file — drop it, tell the uploader.
      {:ok, %{kind: kind, path: path}} ->
        File.rm(path)
        fail(token, avatar_id, "unsupported_kind_#{kind}")

      {:error, reason} ->
        fail(token, avatar_id, to_string(reason))
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp fail(token, avatar_id, reason) do
    Storage.unstage(token)
    avatar = Avatars.get_avatar_by_id(avatar_id)
    Avatars.mark_failed(avatar_id)

    if avatar do
      Goodmao2.Notifications.create(avatar.uploaded_by_user_id, "avatar_failed", %{
        "owner_type" => avatar.owner_type,
        "owner_id" => avatar.owner_id,
        "reason" => reason
      })
    end

    :ok
  end
end
