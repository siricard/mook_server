defmodule MookServerWeb.HealthControllerTest do
  use MookServerWeb.ConnCase

  test "GET /api/health", %{conn: conn} do
    conn = get(conn, ~p"/api/health")

    assert %{"status" => "ok", "service" => "mook_server"} = json_response(conn, 200)
  end
end
