defmodule Thirdparty.MatchIntervalManager do
  use Supervisor

  alias Thirdparty.MatchIntervalManager.Server
  @registry Thirdparty.MatchIntervalManager.Registry
  @dyn_sup Thirdparty.MatchIntervalManager.Supervisor

  ## Public API
  def start_link(_args) do
    Supervisor.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc """
  Increments listener count for `match_id`, starting a per-match Server if first listener.
  """
  def track_listener(match_id) when is_binary(match_id) do
    case Registry.lookup(@registry, match_id) do
      [] ->
        {:ok, _pid} = DynamicSupervisor.start_child(@dyn_sup, {Server, {match_id}})
        Registry.register(@registry, match_id, 1)

      [{_pid, count}] ->
        Registry.update_value(@registry, match_id, &(&1 + 1))
    end

    :ok
  end

  @doc """
  Decrements listener count for `match_id`, terminating the per-match Server when last listener leaves.
  """
  def untrack_listener(match_id) when is_binary(match_id) do
    case Registry.lookup(@registry, match_id) do
      [{pid, 1}] ->
        DynamicSupervisor.terminate_child(@dyn_sup, pid)
        Registry.unregister(@registry, match_id)

      [{_pid, count}] when count > 1 ->
        Registry.update_value(@registry, match_id, &(&1 - 1))

      _ ->
        :noop
    end
  end

  @impl true
  def init(_args) do
    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: @dyn_sup}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
