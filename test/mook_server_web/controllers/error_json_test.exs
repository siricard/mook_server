defmodule MookServerWeb.ErrorJSONTest do
  use MookServerWeb.ConnCase, async: true

  test "renders 404" do
    assert MookServerWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert MookServerWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
