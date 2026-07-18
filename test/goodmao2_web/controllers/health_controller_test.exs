defmodule Goodmao2Web.HealthControllerTest do
  use Goodmao2Web.ConnCase, async: true

  test "GET /health returns 200 ok when the database is reachable", %{conn: conn} do
    conn = get(conn, ~p"/health")
    assert response(conn, 200) == "ok"
  end
end
