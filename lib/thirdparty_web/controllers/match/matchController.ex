defmodule ThirdpartyWeb.Match.MatchController do
  use ThirdpartyWeb, :controller

  require Logger
  alias ThirdpartyWeb.ExternalApis.Match, as: MatchListApi
  alias ThirdpartyWeb.Constant, as: Constant

  @doc """
  GET /api/matches?type=<key>

  - Looks up `game_type()[type_param]`. If missing/invalid, returns 400.
  - Calls the external API; on success returns 200 with `%{status: "ok", data: map}`.
  - On DNS/transport/HTTP errors, returns 502 or upstream status.
  """
  def match_list(conn, %{"type" => type_param}) do
    # 1. Look up the integer code from Constant.game_type()
    case Constant.game_type()[type_param] do
      nil ->
        # The client sent an invalid or unknown type
        conn
        |> put_status(:bad_request)
        |> json(%{status: "error", error: "Invalid `type` parameter: #{inspect(type_param)}"})

      game_type when is_integer(game_type) ->
        # 2. Call the external API
        case MatchListApi.fetch_match_list(game_type) do
          {:ok, map} ->
            # Success: return the raw map under "data"
            conn
            |> put_status(:ok)
            |> json(%{status: "ok", data: map})

          {:error, other} ->
            # Any other unexpected error
            Logger.error("Unexpected fetch_match_list error: #{inspect(other)}")

            conn
            |> put_status(:internal_server_error)
            |> json(%{status: "error", error: "Unexpected error occurred"})
        end

      _ ->
        Logger.error("Unexpected fetch_match_list error")
    end
  end

  # If "type" is not provided at all
  def match_list(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{status: "error", error: "Missing required query parameter: type"})
  end

  def match_rate(conn, %{"eventId" => eventId, "apiType" => apiType}) do
    if eventId == nil do
      conn
      |> put_status(:bad_request)
      |> json(%{status: "error", error: "Missing required query parameter: eventId"})
    end

    apiType = apiType || "2"

    case MatchListApi.fetch_match_rate(apiType, eventId) do
      {:ok, map} ->
        conn
        |> put_status(:ok)
        |> json(%{status: "ok", data: map})

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{status: "error", error: "Failed to fetch match rate: #{inspect(reason)}"})
    end
  end

  # If "type" is not provided at all
  def match_rate(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{status: "error", error: "Missing required query parameter: type and eventId"})
  end
end
