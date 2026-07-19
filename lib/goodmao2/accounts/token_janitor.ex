defmodule Goodmao2.Accounts.TokenJanitor do
  @moduledoc """
  Daily Oban cron that prunes expired auth tokens.

  A thin shell over `Goodmao2.Accounts.delete_expired_tokens/0` — the real logic lives
  in the context so it stays testable without Oban. Scheduled from the `Oban.Plugins.Cron`
  crontab in `config/config.exs`.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Goodmao2.Accounts.delete_expired_tokens()
    :ok
  end
end
