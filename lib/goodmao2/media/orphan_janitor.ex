defmodule Goodmao2.Media.OrphanJanitor do
  @moduledoc """
  Daily Oban cron that sweeps orphaned media bytes (ADR-0005).

  A thin shell over `Goodmao2.Media.delete_orphans/0` — the real logic lives in the context so it
  stays testable without Oban. Scheduled from the `Oban.Plugins.Cron` crontab in `config/config.exs`.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    %{objects: objects, staged: staged} = Goodmao2.Media.delete_orphans()

    if objects + staged > 0 do
      Logger.info("media orphan janitor: removed #{objects} objects, #{staged} staged files")
    end

    :ok
  end
end
