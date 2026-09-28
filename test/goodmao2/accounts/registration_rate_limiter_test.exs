defmodule Goodmao2.Accounts.RegistrationRateLimiterTest do
  # async: false — mutates the global accounts config to force a low cap.
  use ExUnit.Case, async: false

  alias Goodmao2.Accounts.RegistrationRateLimiter, as: Limiter

  test "allows sends up to the hourly cap per address, then refuses" do
    previous = Application.fetch_env!(:goodmao2, Goodmao2.Accounts)

    Application.put_env(
      :goodmao2,
      Goodmao2.Accounts,
      Keyword.put(previous, :registration_emails_per_hour, 2)
    )

    on_exit(fn -> Application.put_env(:goodmao2, Goodmao2.Accounts, previous) end)

    email = "rl-#{System.unique_integer([:positive])}@example.com"

    assert Limiter.check(email) == :ok
    assert Limiter.check(email) == :ok
    assert Limiter.check(email) == {:error, :rate_limited}

    # Keying is case- and whitespace-insensitive, so trivial variations share the budget.
    assert Limiter.check("  " <> String.upcase(email) <> " ") == {:error, :rate_limited}

    # A different address has its own independent budget.
    assert Limiter.check("other-#{System.unique_integer([:positive])}@example.com") == :ok
  end

  test "the sweep drops expired windows and keeps live ones, without crashing the owner" do
    # The sweep once passed the table to `:ets.foldl/3` in the wrong position, so it raised on
    # every run and the restart wiped every counter along with the table.
    table = :registration_email_rate
    now = System.system_time(:second)
    stale = "stale-#{System.unique_integer([:positive])}@example.com"
    live = "live-#{System.unique_integer([:positive])}@example.com"
    :ets.insert(table, {stale, [now - 7200]})
    :ets.insert(table, {live, [now]})

    pid = Process.whereis(Limiter)
    send(pid, :sweep)
    # A synchronous call returns only after the :sweep message has been handled.
    _ = :sys.get_state(pid)

    assert Process.whereis(Limiter) == pid
    assert :ets.lookup(table, stale) == []
    assert [{^live, _}] = :ets.lookup(table, live)
  end
end
