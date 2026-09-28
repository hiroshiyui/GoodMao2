defmodule Goodmao2.Accounts.LoginRateLimiterTest do
  # async: false — sends the shared limiter process a sweep.
  use ExUnit.Case, async: false

  alias Goodmao2.Accounts.LoginRateLimiter, as: Limiter

  test "the sweep drops expired windows and keeps live ones, without crashing the owner" do
    # The sweep once passed the table to `:ets.foldl/3` in the wrong position, so it raised on
    # every run and the restart wiped every counter along with the table: the hourly failed-login
    # and second-factor ceilings were really ten-minute ones.
    table = :login_attempt_rate
    now = System.system_time(:second)
    stale = {:second_factor, -System.unique_integer([:positive])}
    live = {:second_factor, -System.unique_integer([:positive])}
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
