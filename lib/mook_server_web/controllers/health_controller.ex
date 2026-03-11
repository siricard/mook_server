defmodule MookServerWeb.HealthController do
  use MookServerWeb, :controller

  def show(conn, _params) do
    json(conn, %{
      status: "ok",
      service: "mook_server"
    })
  end
end
