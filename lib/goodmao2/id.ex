defmodule Goodmao2.ID do
  @moduledoc """
  Normalizes externally-supplied record ids at the context boundary.

  Route and socket params arrive as strings. Handing one straight to Ecto turns a typo'd
  URL, a stale link, or a crawler into an `Ecto.Query.CastError` — a 400 page on the dead
  render and a crashed LiveView process over the socket — rather than the existence-hiding
  "not found" that every id-based lookup in this app promises. A value above `bigint`
  parses cleanly and then overflows in Postgres, so the range is bounded here too.
  """

  # Postgres `bigint` upper bound; `id` columns are `bigserial`.
  @max_id 9_223_372_036_854_775_807

  @doc """
  Returns `{:ok, id}` for a positive, in-range integer or its string form; `:error` otherwise.

  Callers map `:error` onto whatever "no such record" looks like for them — `{:error,
  :not_found}` or `nil` — so a malformed id is indistinguishable from an inaccessible one.
  """
  @spec normalize(term()) :: {:ok, pos_integer()} | :error
  def normalize(id) when is_integer(id) and id > 0 and id <= @max_id, do: {:ok, id}

  def normalize(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> normalize(n)
      _ -> :error
    end
  end

  def normalize(_), do: :error
end
