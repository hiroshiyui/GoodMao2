defmodule Goodmao2.Pets.GrantRateLimiter do
  @moduledoc """
  A tiny per-granter sliding-window limiter for access-grant attempts (ADR-0014).

  `Pets.grant_access/3` resolves the grantee by `@handle` *or email*, and must say whether it
  found one — an owner who mistyped an address needs to know. That answer is a membership oracle
  for email addresses, which registration, magic-link and messaging all carefully avoid. Rather
  than take email sharing away (families share by email), cap *how many* lookups one account can
  make: creating a pet is free, so the cap is per granter, not per pet. Charged on every attempt,
  found or not, before the lookup. Mirrors `Goodmao2.Messaging.SendRateLimiter`: a public ETS
  table checked inline, the process only keeps it alive. The window is one hour; the ceiling is
  `:grant_attempts_per_hour` under `Goodmao2.Pets`.
  """
  use GenServer

  @table :grant_attempt_rate
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

  @doc "Records a grant attempt for `user_id`, or `{:error, :rate_limited}` if over the hourly cap."
  def check(user_id) do
    limit = Application.fetch_env!(:goodmao2, Goodmao2.Pets)[:grant_attempts_per_hour]
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
