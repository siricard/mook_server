defmodule MookServerWeb.HealthControllerTest do
  use MookServerWeb.ConnCase

  defp assert_health_response(conn, path) do
    conn = get(conn, path)

    assert %{"status" => "ok", "service" => "mook_server"} = json_response(conn, 200)
  end

  test "GET /api/health", %{conn: conn} do
    assert_health_response(conn, ~p"/api/health")
  end

  test "GET /api/v1/health", %{conn: conn} do
    assert_health_response(conn, ~p"/api/v1/health")
  end
end
