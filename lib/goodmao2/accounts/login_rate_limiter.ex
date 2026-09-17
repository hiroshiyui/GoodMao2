defmodule Goodmao2.Accounts.LoginRateLimiter do
  @moduledoc """
  A tiny sliding-window limiter for **failed** login attempts: email+password failures per
  target email, and second-factor failures per user.

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

  Rows are keyed by the SHA-256 of the normalized email, never the email itself: the address is
  attacker-supplied and unbounded (a request body can carry megabytes), and every failure keeps
  its row for up to an hour, so storing it raw let an unauthenticated flood of oversized
  addresses exhaust node memory.

  **Second factor.** The pending-2FA attempt counter lives in the session, and the session is a
  signed *cookie* — a client that replays its pre-failure cookie never sees the count rise, so
  that counter alone bounds nothing. `reserve_second_factor/1` keeps the authoritative count here,
  per user id, under the same hourly ceiling. It charges the attempt *before* the factor is
  evaluated — a check-then-record would let a concurrent burst all pass the check while their
  verifications run — and only a successful factor clears it. Reaching the second-factor stage
  already requires the password, so this cannot be tripped by a stranger.

  Owns a public ETS table so callers check inline without a GenServer round-trip; the process
  exists only to keep the table alive. The window is one hour and the ceiling is
  `config :goodmao2, Goodmao2.Accounts, :login_attempts_per_hour`.
  """
  use GenServer

  @table :login_attempt_rate
  @window_seconds 3600
  @sweep_interval_ms :timer.minutes(10)

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

    schedule_sweep()
    {:ok, nil}
  end

  # Rows are keyed by an unauthenticated, attacker-chosen address, and `clear/1` only fires
  # on a *successful* login — which never happens for a synthetic one. Without this sweep a
  # flood of distinct addresses grows the table forever (each is its own key, so the
  # per-address cap never engages) until the node runs out of memory.
  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.system_time(:second) - @window_seconds

    @table
    |> :ets.foldl(
      fn {key, times}, stale ->
        if Enum.any?(times, &(&1 > cutoff)), do: stale, else: [key | stale]
      end,
      []
    )
    |> Enum.each(&:ets.delete(@table, &1))

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  @doc "Returns `:ok` while failures for `email` are under the hourly cap, else `{:error, :rate_limited}`."
  def check(email) when is_binary(email), do: check_key(email_key(email))

  @doc "Records a failed login attempt for `email`."
  def record_failure(email) when is_binary(email), do: record_key(email_key(email))

  @doc "Clears the failure counter for `email` (called after a successful login)."
  def clear(email) when is_binary(email), do: clear_key(email_key(email))

  @doc """
  Spends one of the user's hourly second-factor attempts (TOTP, recovery code, or security key)
  ahead of evaluating it. Returns `:ok`, or `{:error, :rate_limited}` — without spending — once
  the budget is gone.
  """
  def reserve_second_factor(user_id) when is_integer(user_id) do
    key = {:second_factor, user_id}

    with :ok <- check_key(key), do: record_key(key)
  end

  @doc "Clears the user's second-factor failure counter (called after a factor succeeds)."
  def clear_second_factor(user_id) when is_integer(user_id),
    do: clear_key({:second_factor, user_id})

  defp check_key(key) do
    if length(recent_failures(key)) >= limit(), do: {:error, :rate_limited}, else: :ok
  end

  defp record_key(key) do
    now = System.system_time(:second)
    :ets.insert(@table, {key, [now | recent_failures(key)]})
    :ok
  end

  defp clear_key(key) do
    :ets.delete(@table, key)
    :ok
  end

  defp email_key(email),
    do: {:email, :crypto.hash(:sha256, email |> String.trim() |> String.downcase())}

  defp limit, do: Application.fetch_env!(:goodmao2, Goodmao2.Accounts)[:login_attempts_per_hour]

  defp recent_failures(key) do
    cutoff = System.system_time(:second) - @window_seconds

    case :ets.lookup(@table, key) do
      [{^key, times}] -> Enum.filter(times, &(&1 > cutoff))
      [] -> []
    end
  end
end
