defmodule Goodmao2.Media.RateLimiter do
  @moduledoc """
  A tiny per-user sliding-window rate limiter for media uploads (ADR-0005).

  Owns an ETS table; each check-and-record is serialized through the process, so a parallel
  burst cannot overshoot the cap. The window is one hour and the ceiling is the
  `:rate_limit_per_hour` config. Uploads are the highest-cost, most-abusable write, so this
  caps how many any one account can drive.
  """
  use GenServer

  @table :media_upload_rate
  @window_seconds 3600

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, nil}
  end

  @doc "Records an upload for `user_id`, or `{:error, :rate_limited}` if over the hourly cap."
  def check(user_id) do
    # Through the process, not inline: the ETS read-then-insert below is two operations, so
    # a parallel burst that all read "limit - 1 so far" would all pass, and concurrent
    # inserts would overwrite each other's timestamps. Serialized, exactly `limit` succeed.
    GenServer.call(__MODULE__, {:check, user_id})
  end

  @impl true
  def handle_call({:check, user_id}, _from, state), do: {:reply, record(user_id), state}

  defp record(user_id) do
    limit = Application.fetch_env!(:goodmao2, Goodmao2.Media)[:rate_limit_per_hour]
    now = System.system_time(:second)
    cutoff = now - @window_seconds

    recent =
      case :ets.lookup(@table, user_id) do
        [{^user_id, times}] -> Enum.filter(times, &(&1 > cutoff))
        [] -> []
      end

    if length(recent) >= limit do
      {:error, :rate_limited}
    else
      :ets.insert(@table, {user_id, [now | recent]})
      :ok
    end
  end
end
