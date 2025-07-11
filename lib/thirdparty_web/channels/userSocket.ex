defmodule ThirdpartyWeb.UserSocket do
  use Phoenix.Socket

  require Logger
  alias Thirdparty.MatchIntervalSupervisor
  alias ThirdpartyWeb.Presence
  alias Phoenix.PubSub

  ## Channels
  channel("matches:lobby", ThirdpartyWeb.MatchChannel)

  @impl true
  def connect(
        %{"roleName" => role_name, "matchIdArray" => match_ids, "userId" => userId}=params,
        socket,
        _info
      ) do
    ids =
      match_ids
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    Logger.debug("12 #{role_name}")

    if ids == [] or role_name in [nil, ""] do
      :error
    else
      socket =
        socket
        |> assign(:role_name, role_name)
        |> assign(:match_ids, ids)
        |> assign(:userId, userId)
        |> assign(:isSession, params["isSession"])

      {:ok, socket}
    end
  end

  def connect(_, _, _), do: :error

  @impl true
  def id(_socket), do: nil
end
