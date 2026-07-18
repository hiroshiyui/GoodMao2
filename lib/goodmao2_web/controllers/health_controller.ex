defmodule Goodmao2Web.HealthController do
  @moduledoc """
  A tiny liveness/readiness probe. Returns `200 ok` when the database is
  reachable, `503 unavailable` otherwise — the hook deploys and monitoring hang
  off. Unauthenticated and cheap by design.
  """
  use Goodmao2Web, :controller

  alias Goodmao2.Repo

  def index(conn, _params) do
    case db_reachable?() do
      true -> send_resp(conn, 200, "ok")
      false -> send_resp(conn, 503, "unavailable")
    end
  end

  defp db_reachable? do
    Ecto.Adapters.SQL.query!(Repo, "SELECT 1", [])
    true
  rescue
    _ -> false
  end
end
