defmodule Goodmao2.Accounts.LoginRateLimiter do
  @moduledoc """
  A tiny per-email sliding-window limiter for **failed** email+password login attempts.

  Bcrypt's cost blunts offline-scale guessing, but the password `create` path had no online
  throttle, so an attacker could try passwords at request speed against a known address. This
  caps *failed* attempts per target email per hour; a successful login clears the counter, so a
  legitimate user who eventually types the right password is never held back. On reaching the
  cap the login form returns the same generic "Invalid email or password" message, so it adds no
  user-enumeration oracle.

  Keyed by the normalized email (proxy-safe, needs no client IP), mirroring
  `Goodmao2.Accounts.RegistrationRateLimiter`. Like that limiter, it is per-address: an attacker
  can deny one victim's password login for up to an hour, but the victim can still use the
  (separately throttled) magic-link path. A distributed flood across many addresses is a
  CAPTCHA / edge-WAF concern, tracked separately.

  Owns a public ETS table so callers check inline without a GenServer round-trip; the process
  exists only to keep the table alive. The window is one hour and the ceiling is
  `config :goodmao2, Goodmao2.Accounts, :login_attempts_per_hour`.
  """
  use GenServer

  @table :login_attempt_rate
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

  @doc "Returns `:ok` while failures for `email` are under the hourly cap, else `{:error, :rate_limited}`."
  def check(email) when is_binary(email) do
    if length(recent_failures(key(email))) >= limit() do
      {:error, :rate_limited}
    else
      :ok
    end
  end

  @doc "Records a failed login attempt for `email`."
  def record_failure(email) when is_binary(email) do
    k = key(email)
    now = System.system_time(:second)
    :ets.insert(@table, {k, [now | recent_failures(k)]})
    :ok
  end

  @doc "Clears the failure counter for `email` (called after a successful login)."
  def clear(email) when is_binary(email) do
    :ets.delete(@table, key(email))
    :ok
  end

  defp key(email), do: email |> String.trim() |> String.downcase()

  defp limit, do: Application.fetch_env!(:goodmao2, Goodmao2.Accounts)[:login_attempts_per_hour]

  defp recent_failures(key) do
    cutoff = System.system_time(:second) - @window_seconds

    case :ets.lookup(@table, key) do
      [{^key, times}] -> Enum.filter(times, &(&1 > cutoff))
      [] -> []
    end
  end
end
