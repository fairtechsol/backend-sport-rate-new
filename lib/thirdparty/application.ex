defmodule Thirdparty.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    redis_conf = Application.fetch_env!(:thirdparty, :redis)
    redis_host = redis_conf[:host]
    redis_port = redis_conf[:port]
    redis_name = redis_conf[:name] || :my_redis

    children = [
      {Cachex, name: :match_list_cache},
      # ✅ Start Registry FIRST, and use the exact name expected by your GenServers
      {Registry, keys: :unique, name: Thirdparty.MatchIntervalManager.Registry},
      ThirdpartyWeb.Telemetry,
      Thirdparty.Repo,
      {DNSCluster, query: Application.get_env(:thirdparty, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Thirdparty.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: Thirdparty.Finch},
      # Start a worker by calling: Thirdparty.Worker.start_link(arg)
      # {Thirdparty.Worker, arg},
      # Start to serve requests, typically the last entry
      ThirdpartyWeb.Endpoint,
      Thirdparty.MatchIntervalManager,
      {Redix, name: redis_name, host: redis_host, port: redis_port},
      ThirdpartyWeb.Presence
      # if you’re also using Presence elsewhere
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Thirdparty.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ThirdpartyWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
