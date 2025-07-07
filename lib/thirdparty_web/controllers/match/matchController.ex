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
    Logger.debug("match_list called with type: #{inspect(type_param)}")

    case Constant.game_type()[type_param] do
      nil ->
        conn
        |> put_status(:bad_request)
        |> json(%{status: "error", error: "Invalid `type` parameter: #{inspect(type_param)}"})

      game_type when is_integer(game_type) ->
        fetch_fun = fn _key ->
          case MatchListApi.fetch_match_list(game_type) do
            # On success, commit into cache with a 60 s TTL
            {:ok, map} -> {:commit, map, ttl: :timer.seconds(60)}
            # On error, ignore so we don’t cache failures
            {:error, err} -> {:ignore, err}
          end
        end

        case Cachex.fetch(:match_list_cache, game_type, fetch_fun) do
          # cache-only hit
          {:ok, map} ->
            Logger.debug("Cache hit for match_list: #{inspect(map)}")

            conn
            |> put_status(:ok)
            |> json(%{status: "ok", data: map})

          # miss → fetched → commit
          {:commit, map, _} ->
            Logger.debug("Cache write for match_list comm: #{inspect(map)}")

            conn
            |> put_status(:ok)
            |> json(%{status: "ok", data: map})

          # upstream error
          {:ignore, err} ->
            Logger.error("fetch_match_list error: #{inspect(err)}")

            conn
            |> put_status(:internal_server_error)
            |> json(%{status: "error", error: "Unexpected error occurred"})

          other ->
            Logger.error("Unexpected Cachex response: #{inspect(other)}")

            conn
            |> put_status(:internal_server_error)
            |> json(%{status: "error", error: "Server configuration error"})
        end

      _ ->
        Logger.error("Unexpected game_type for #{inspect(type_param)}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{status: "error", error: "Server configuration error"})
    end
  end

  # If "type" is not provided at all
  def match_list(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{status: "error", error: "Missing required query parameter: type"})
  end

  def match_rate_cricket(conn, %{"eventId" => eventId} = params) do
    if eventId == nil do
      conn
      |> put_status(:bad_request)
      |> json(%{status: "error", error: "Missing required query parameter: eventId"})
    end

    apiType = Map.get(params, "apiType", "2")

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
  def match_rate_cricket(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{status: "error", error: "Missing required query parameter: type and eventId"})
  end

  def match_rate_football(conn, %{"eventId" => eventId} = params) do
    apiType = Map.get(params, "apiType", "3")

    if eventId == nil do
      conn
      |> put_status(:bad_request)
      |> json(%{status: "error", error: "Missing required query parameter: eventId"})
    end

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
  def match_rate_football(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{status: "error", error: "Missing required query parameter: eventId"})
  end

  def get_score_card(conn, %{"eventId" => eventId}) do
    case MatchListApi.get_score_card(eventId) do
      {:ok, map} ->
        conn
        |> put_status(:ok)
        |> json(%{status: "ok", data: map})

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{status: "error", error: "Failed to fetch score card: #{inspect(reason)}"})
    end
  end

  def get_score_card(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{status: "error", error: "Missing required query parameter: eventId"})
  end
end
