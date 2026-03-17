defmodule MookServerWeb.AshJsonApiRouter do
  @domains Application.compile_env(:mook_server, :ash_domains, [])

  use AshJsonApi.Router,
    domains: @domains,
    open_api: "/open_api"
end
