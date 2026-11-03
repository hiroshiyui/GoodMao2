defmodule Goodmao2.Notifications.PushRateLimiter do
  @moduledoc """
  A tiny per-user sliding-window rate limiter for push-subscription writes.

  Mirrors `Goodmao2.Media.RateLimiter`: owns an ETS table whose check-and-record is serialized
  through the process. Caps how often one authenticated account
  can hammer the subscribe/unsubscribe endpoint. The window is one hour; the ceiling is the
  `:push_subscribe_per_hour` config under `Goodmao2.Notifications`.
  """
  use GenServer

  @table :push_subscribe_rate
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

  @doc "Records a write for `user_id`, or `{:error, :rate_limited}` if over the hourly cap."
  def check(user_id) do
    # Through the process, not inline: the ETS read-then-insert below is two operations, so
    # a parallel burst that all read "limit - 1 so far" would all pass, and concurrent
    # inserts would overwrite each other's timestamps. Serialized, exactly `limit` succeed.
    GenServer.call(__MODULE__, {:check, user_id})
  end

  @impl true
  def handle_call({:check, user_id}, _from, state), do: {:reply, record(user_id), state}

  defp record(user_id) do
    limit =
      Application.get_env(:goodmao2, Goodmao2.Notifications, [])[:push_subscribe_per_hour] || 60

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
