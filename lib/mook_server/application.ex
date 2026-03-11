defmodule MookServer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MookServerWeb.Telemetry,
      MookServer.Repo,
      {DNSCluster, query: Application.get_env(:mook_server, :dns_cluster_query) || :ignore},
      {Oban,
       AshOban.config(
         Application.fetch_env!(:mook_server, :ash_domains),
         Application.fetch_env!(:mook_server, Oban)
       )},
      {Phoenix.PubSub, name: MookServer.PubSub},
      # Start a worker by calling: MookServer.Worker.start_link(arg)
      # {MookServer.Worker, arg},
      # Start to serve requests, typically the last entry
      MookServerWeb.Endpoint,
      {AshAuthentication.Supervisor, [otp_app: :mook_server]}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: MookServer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MookServerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
