defmodule Goodmao2.Settings.Cache do
  @moduledoc """
  A tiny read-through ETS cache for `Goodmao2.Settings`.

  Owns a public ETS table so a setting read (e.g. the VAPID public key on every full page
  load) is answered without a DB round-trip; the process exists only to keep the table
  alive (like `Goodmao2.Media.RateLimiter`). `Goodmao2.Settings` write-through-updates it
  on every `put/2`.

  The cache is **disabled in the test env** (`config :goodmao2, Goodmao2.Settings, cache:
  false`): a global ETS table shared across the async sandbox would leak one test's writes
  into another, so tests read straight from the DB where the Ecto sandbox isolates them.
  The enabled/disabled decision is made at runtime so the compiler keeps both `fetch/1`
  return shapes reachable in every env.
  """
  use GenServer

  @table :goodmao2_settings

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    if enabled?() do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    {:ok, nil}
  end

  @doc "Returns `{:ok, value}` (value may be nil) on a hit, or `:miss`."
  def fetch(key) do
    if enabled?() do
      case :ets.lookup(@table, key) do
        [{^key, value}] -> {:ok, value}
        [] -> :miss
      end
    else
      :miss
    end
  end

  @doc "Caches `value` (possibly nil) for `key`. A no-op when the cache is disabled."
  def put(key, value) do
    if enabled?(), do: :ets.insert(@table, {key, value}), else: true
  end

  defp enabled?, do: Application.get_env(:goodmao2, Goodmao2.Settings, [])[:cache] != false
end
