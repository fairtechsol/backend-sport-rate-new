require Logger

defmodule Thirdparty.MatchIntervalManager do
  use Supervisor

  alias Thirdparty.MatchIntervalManager.Server

  @registry Thirdparty.MatchIntervalManager.Registry
  @dyn_sup Thirdparty.MatchIntervalManager.Supervisor

  def start_link(_args) do
    Supervisor.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    children = [
      # 2) DynamicSupervisor for per-match GenServers
      {DynamicSupervisor, strategy: :one_for_one, name: @dyn_sup}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  @doc """
  Called when a client joins a match:
    - If first listener, start the GenServer and set count = 1
    - Otherwise increment existing count
  """
  def track_listener(match_id) when is_binary(match_id) do
    lookup = Registry.lookup(@registry, match_id)
    Logger.debug("track_listener lookup for #{match_id}: #{inspect(lookup)}")

    case lookup do
      [] ->
        # first listener -> start the Server
        spec = Server.child_spec(match_id)

        case DynamicSupervisor.start_child(@dyn_sup, spec) do
          {:ok, _pid} ->
            Logger.debug("Started Server for #{match_id}")
            :ok

          {:error, {:already_started, pid}} ->
            # This can happen in race conditions
            Server.increment_listener(pid)
            :ok
        end

        Logger.debug("Started Server for #{match_id}")

      [{pid, _}] ->
        Server.increment_listener(pid)
        :ok
    end

    :ok
  end

  @doc """
  Called when a client leaves a match:
    - If that was the last listener, terminate the GenServer and unregister
    - Otherwise decrement the count
  """
  def untrack_listener(match_id) when is_binary(match_id) do
    Logger.debug("untrack_listener for #{match_id}")

    case Registry.lookup(@registry, match_id) do
      [{pid, _}] ->
        Server.decrement_listener(pid)
        :ok

      [] ->
        Logger.debug("No server found for #{match_id}")
        :ok
    end
  end
end
