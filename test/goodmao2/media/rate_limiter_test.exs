defmodule Goodmao2.Media.RateLimiterTest do
  # async: false — mutates the global media config to force a low cap.
  use ExUnit.Case, async: false

  alias Goodmao2.Media.RateLimiter

  test "allows uploads up to the hourly cap, then refuses" do
    previous = Application.fetch_env!(:goodmao2, Goodmao2.Media)
    Application.put_env(:goodmao2, Goodmao2.Media, Keyword.put(previous, :rate_limit_per_hour, 2))
    on_exit(fn -> Application.put_env(:goodmao2, Goodmao2.Media, previous) end)

    user_id = System.unique_integer([:positive])

    assert RateLimiter.check(user_id) == :ok
    assert RateLimiter.check(user_id) == :ok
    assert RateLimiter.check(user_id) == {:error, :rate_limited}
  end
end
