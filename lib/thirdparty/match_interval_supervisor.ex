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
      {DynamicSupervisor, strategy: :one_for_one, name: @dyn_sup}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  # ASYNC: Fire-and-forget tracking
  def track_listener(match_id) when is_binary(match_id) do
    Task.start(fn ->
      case Registry.lookup(@registry, match_id) do
        [] ->
          spec = Server.child_spec(match_id)

          case DynamicSupervisor.start_child(@dyn_sup, spec) do
            {:ok, _pid} -> :ok
            {:error, {:already_started, pid}} -> Server.increment_listener(pid)
          end

        [{pid, _}] ->
          Server.increment_listener(pid)
      end
    end)

    :ok
  end

  # ASYNC: Fire-and-forget untracking
  def untrack_listener(match_id) when is_binary(match_id) do
    Task.start(fn ->
      case Registry.lookup(@registry, match_id) do
        [{pid, _}] -> Server.decrement_listener(pid)
        [] -> Logger.debug("No server for #{match_id}")
      end
    end)

    :ok
  end
end
