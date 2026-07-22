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
end
