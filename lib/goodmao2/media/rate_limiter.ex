defmodule Goodmao2.Media.RateLimiter do
  @moduledoc """
  A tiny per-user sliding-window rate limiter for media uploads (ADR-0005).

  Owns a public ETS table so callers check inline without a GenServer round-trip; the process
  exists only to keep the table alive. The window is one hour and the ceiling is the
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
