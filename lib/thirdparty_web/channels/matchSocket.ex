defmodule ThirdpartyWeb.MatchChannel do
  use Phoenix.Channel

  require Logger
  alias Thirdparty.MatchIntervalManager
  alias ThirdpartyWeb.Presence
  alias Phoenix.PubSub

  @impl true
  def join("matches:lobby", _payload, socket) do
    role = socket.assigns.role_name
    ids = socket.assigns.match_ids
    isSession = socket.assigns[:isSession]

    Logger.debug("Joining matches:lobby with role: #{role} and match_ids: #{inspect(ids)} #{inspect(socket.assigns)}")

    for id <- ids do
      topic = topic_for(id, role, isSession)
      PubSub.subscribe(Thirdparty.PubSub, topic)
      MatchIntervalManager.track_listener(id)
    end

    send(self(), :after_join)
    {:ok, socket}
  end

  @impl true
  def handle_info(:after_join, socket) do
    userId = socket.assigns.userId || UUID.uuid4()
    key = "user:#{userId}"

    Presence.track(self(), "matches:lobby", key, %{
      role: userId,
      online_at: inspect(System.system_time(:second))
    })

    push(socket, "presence_state", Presence.list("matches:lobby"))

    {:noreply, socket}
  end

  @impl true
  def handle_in(
        "disconnectCricketData",
        %{"matchId" => id, "roleName" => role}=params,
        socket
      ) do
        isSession=params["isSession"]
    PubSub.unsubscribe(Thirdparty.PubSub, topic_for(id, role, isSession))
    MatchIntervalManager.untrack_listener(id)
    {:noreply, socket}
  end

  @impl true
  def handle_in("leaveAllRoom", _payload, socket) do
    role = socket.assigns.role_name
    isSession = socket.assigns[:isSession]

    for id <- socket.assigns.match_ids do
      PubSub.unsubscribe(Thirdparty.PubSub, topic_for(id, role, isSession))
      MatchIntervalManager.untrack_listener(id)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:match_data, _id, payload}, socket) do
    push(socket, "match_data", payload)
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    for id <- socket.assigns.match_ids do
      MatchIntervalManager.untrack_listener(id)
    end

    :ok
  end

  defp topic_for(id, "expert", "true"), do: "match_expert_session:#{id}"
  defp topic_for(id, "expert", _), do: "match_expert:#{id}"
  defp topic_for(id, _, _), do: "match:#{id}"
end
