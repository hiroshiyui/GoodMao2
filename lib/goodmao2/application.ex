defmodule Goodmao2.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Goodmao2Web.Telemetry,
      Goodmao2.Repo,
      {Oban, Application.fetch_env!(:goodmao2, Oban)},
      {DNSCluster, query: Application.get_env(:goodmao2, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Goodmao2.PubSub},
      # Owns the media-upload rate-limit ETS table (ADR-0005).
      Goodmao2.Media.RateLimiter,
      # Start a worker by calling: Goodmao2.Worker.start_link(arg)
      # {Goodmao2.Worker, arg},
      # Start to serve requests, typically the last entry
      Goodmao2Web.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Goodmao2.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    Goodmao2Web.Endpoint.config_change(changed, removed)
    :ok
  end
end
