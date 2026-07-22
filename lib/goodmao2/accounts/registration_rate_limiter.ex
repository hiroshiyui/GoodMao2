defmodule Goodmao2.Accounts.RegistrationRateLimiter do
  @moduledoc """
  A tiny per-email sliding-window limiter for registration / magic-link emails.

  Registration and the magic-link login page both send an email to an **unauthenticated**
  address, so without a cap an attacker can drive unbounded outbound mail (Amazon SES cost +
  sender-reputation damage from bounces) and churn unconfirmed rows. Keyed by the normalized
  target email, so it is proxy-safe (needs no client IP) and blunts resend-to-one-address
  abuse. It does **not** stop a distributed flood across many distinct addresses — that is a
  CAPTCHA / edge-WAF concern, tracked separately.

  Owns a public ETS table so callers check inline without a GenServer round-trip; the process
  exists only to keep the table alive. Mirrors `Goodmao2.Media.RateLimiter`. The window is one
  hour and the ceiling is `config :goodmao2, Goodmao2.Accounts, :registration_emails_per_hour`.
  """
  use GenServer

  @table :registration_email_rate
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

  @doc "Records a send for `email`, or `{:error, :rate_limited}` if over the hourly cap."
  def check(email) when is_binary(email) do
    key = email |> String.trim() |> String.downcase()
    limit = Application.fetch_env!(:goodmao2, Goodmao2.Accounts)[:registration_emails_per_hour]
    now = System.system_time(:second)
    cutoff = now - @window_seconds

    recent =
      case :ets.lookup(@table, key) do
        [{^key, times}] -> Enum.filter(times, &(&1 > cutoff))
        [] -> []
      end

    if length(recent) >= limit do
      {:error, :rate_limited}
    else
      :ets.insert(@table, {key, [now | recent]})
      :ok
    end
  end
end
