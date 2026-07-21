defmodule Goodmao2.Accounts.WebAuthnChallenges do
  @moduledoc """
  ETS-backed, single-use store for WebAuthn registration/authentication challenges
  (ADR-0013).

  A `Wax.Challenge` is short-lived (60 s) and must be used exactly once. This GenServer
  owns a named ETS table mapping a random token to `{challenge, user_id, expires_at}`.
  The token travels to the browser in a hidden form field and comes back on the
  ceremony's completion POST — the challenge itself never leaves the server. A sweeper
  removes expired entries every 30 s.

  ## Security

    * `pop/2` uses `:ets.take` — the entry is removed on first retrieval (single-use).
    * Expired entries are never returned, even before the sweeper runs.
    * The token is 16 cryptographically-random bytes (base64url).
    * `user_id` is checked on pop, preventing cross-user challenge reuse.
  """

  use GenServer

  @table :webauthn_challenges
  @ttl_seconds 60
  @sweep_interval_ms 30_000

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Stores `challenge` for `user_id`, returning a random single-use token."
  @spec put(integer(), Wax.Challenge.t()) :: String.t()
  def put(user_id, challenge) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    expires_at = System.system_time(:second) + @ttl_seconds
    :ets.insert(@table, {token, {challenge, user_id, expires_at}})
    token
  end

  @doc """
  Atomically retrieves and removes the challenge for `token`.

  Returns `{:ok, challenge}` only when the token exists, belongs to `user_id`, and has
  not expired; `{:error, :not_found}` otherwise.
  """
  @spec pop(String.t(), integer()) :: {:ok, Wax.Challenge.t()} | {:error, :not_found}
  def pop(token, user_id) when is_binary(token) do
    case :ets.take(@table, token) do
      [{^token, {challenge, ^user_id, expires_at}}] ->
        if System.system_time(:second) <= expires_at do
          {:ok, challenge}
        else
          {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  def pop(_, _), do: {:error, :not_found}

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    schedule_sweep()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:second)

    # Erlang match spec: delete rows whose expires_at (:"$1") is =< now.
    :ets.select_delete(@table, [{{:_, {:_, :_, :"$1"}}, [{:"=<", :"$1", now}], [true]}])

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
