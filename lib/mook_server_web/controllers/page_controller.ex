defmodule MookServerWeb.PageController do
  use MookServerWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
