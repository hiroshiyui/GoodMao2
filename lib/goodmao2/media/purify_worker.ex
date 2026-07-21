defmodule Goodmao2.Media.PurifyWorker do
  @moduledoc """
  Purifies one staged upload off the request path and attaches it to its log entry (ADR-0005).

  Enqueued (transactionally) by `Media.create_life_log/4`, one job per uploaded file. It reads the
  raw bytes from staging, runs the ffmpeg purifier, and — on success — inserts the ready
  `media_assets` row and stores the clean bytes (`Media.attach_purified_asset/2`), which
  re-broadcasts the entry so the media appears live on the timeline.

  Failure handling:

    * **Missing staged file** — already processed (or a retry after success); a no-op `:ok`.
    * **Classified purify failure** (a corrupt/oversized/disallowed file that slipped past the
      client accept-filter) — terminal: unstage, notify the uploader with a `media_failed` bell,
      and return `:ok` so Oban does not retry a file that can never succeed.
    * **Attach/store error** (e.g. a transient disk write) — return `{:error, _}` so Oban retries;
      the asset insert + byte write are one transaction, so a failed attempt leaves no row.

  Idempotency: the staged file is unstaged only after a successful attach, so a retry re-purifies
  cleanly. A hard crash in the narrow window between the attach commit and the unstage could, on
  retry, attach the same file twice (a duplicate photo) — tolerated as cosmetic and rare.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Goodmao2.Media
  alias Goodmao2.Media.Storage

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    %{
      "token" => token,
      "log_entry_id" => log_entry_id,
      "pet_id" => pet_id,
      "uploaded_by_user_id" => uploaded_by_user_id
    } = args

    staged = Storage.staged_path(token)

    if File.exists?(staged) do
      params = %{
        log_entry_id: log_entry_id,
        pet_id: pet_id,
        uploaded_by_user_id: uploaded_by_user_id,
        caption: args["caption"]
      }

      process(staged, token, params)
    else
      :ok
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  # The only File.rm targets `purified.path` — a temp file the purifier itself just generated,
  # never a user-controlled path. Staged bytes are removed via Storage.unstage/1 (validated token).
  defp process(staged, token, params) do
    case Media.purify(staged) do
      {:ok, purified} ->
        result = Media.attach_purified_asset(params, purified)
        File.rm(purified.path)

        case result do
          {:ok, _asset} ->
            Storage.unstage(token)
            :ok

          # Transient (e.g. disk) — keep the staged bytes and let Oban retry.
          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        # A file that can never purify — drop it and tell the uploader, without retrying.
        Storage.unstage(token)
        notify_failure(params, reason)
        :ok
    end
  end

  defp notify_failure(params, reason) do
    Goodmao2.Notifications.create(params.uploaded_by_user_id, "media_failed", %{
      "pet_id" => params.pet_id,
      "log_entry_id" => params.log_entry_id,
      "reason" => to_string(reason)
    })
  end
end
