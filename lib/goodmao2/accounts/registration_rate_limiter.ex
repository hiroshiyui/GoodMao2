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

  # Rows are keyed by an unauthenticated, attacker-chosen address and nothing else ever
  # removes them, so a flood of distinct addresses would grow the table without bound (each
  # is its own key, so the per-address cap never engages). Expired windows are dropped here.
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
