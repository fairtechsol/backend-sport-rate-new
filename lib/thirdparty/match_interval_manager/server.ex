require Logger

defmodule Thirdparty.MatchIntervalManager.Server do
  @moduledoc """
  A GenServer that:
   1. Keeps track of how many “listeners” currently want data for each match_id.
   2. If the listener‐count for a match_id goes from 0 → 1, it starts a periodic fetch loop.
   3. If the listener‐count for a match_id goes from 1 → 0, it cancels that loop.
  """

  use GenServer
  alias Phoenix.PubSub

  # e.g. 2 seconds; match your `liveGameTypeTime`
  @tick_us String.to_integer(System.get_env("GAME_INTERVAL") || "300")
  ## Client API
  def start_link(match_id) do
    GenServer.start_link(__MODULE__, match_id, name: via(match_id))
  end

  def child_spec(match_id) do
    %{
      id: {__MODULE__, match_id},
      start: {__MODULE__, :start_link, [match_id]},
      # Crucial: prevents automatic restart
      restart: :temporary
    }
  end

  @impl true
  def init(match_id) do
    timer_ref = :timer.send_interval(@tick_us, :tick)

    {:ok, %{match_id: match_id, listener_count: 1, timer_ref: timer_ref}}
  end

  @impl true
  def handle_cast(:increment, state) do
    Logger.debug(
      "Incrementing listener count for match_id: #{state.match_id} #{state.listener_count}"
    )

    new_state = %{state | listener_count: state.listener_count + 1}
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:decrement, state) do
    Logger.debug(
      "Decrementing listener count for match_id: #{state.match_id} #{state.listener_count}"
    )

    new_count = state.listener_count - 1

    Logger.debug(
      "Decrementing listener count for match_id: #{state.match_id}, new count: #{new_count}"
    )

    if new_count == 0 do
      # Last listener - stop server and interval
      {:stop, :normal, state}
    else
      {:noreply, %{state | listener_count: new_count}}
    end
  end

  @impl true
  # Every @fetch_interval_ms, we receive {:perform_fetch, match_id}
  # → fetch fresh data from Redis, then broadcast it on PubSub
  def handle_info(:tick, state) do
    # timer_ref = schedule_tick()
    match_key = "#{state.match_id}_match"
    match_detail = fetch_match_detail_from_redis(match_key)

    Task.start(fn -> do_broadcast(state.match_id) end)

    {:noreply, state}
  end

  defp do_broadcast(match_id) do
    {user_data, expert_data} = fetch_data(match_id)

    PubSub.broadcast(Thirdparty.PubSub, "match:#{match_id}", {:match_data, match_id, user_data})

    PubSub.broadcast(
      Thirdparty.PubSub,
      "match_expert:#{match_id}",
      {:match_data, match_id, expert_data}
    )
  end

  # defp schedule_tick do
  #   Process.send_after(self(), :tick, @tick_us)
  # end

  defp fetch_data(match_id) do
    # Here we integrate the original getCricketData logic.
    # Fetch raw match detail from Redis or ETS
    match_key = "#{match_id}_match"
    match_detail = fetch_match_detail_from_redis(match_key)

    case match_detail do
      %{"marketId" => market_id} ->
        user_task = Task.async(fn -> getCricketData(match_id, market_id, match_detail) end)
        score_task = Task.async(fn -> get_score(match_detail["eventId"]) end)
        # Await both results
        {user_data, expert_data} = Task.await(user_task)
        score = Task.await(score_task)
        Logger.debug("Fetching data for match_id: #{inspect(score)}, market_id: #{market_id}")
        user_data=Map.put(user_data, "scoreBoard", score)

        {user_data, expert_data}

      _ ->
        %{error: "no match detail", match_id: match_id}
    end
  end

  defp get_score(eventId) do
    alias ThirdpartyWeb.ExternalApis.Match, as: MatchListApi

    case MatchListApi.get_score_card(eventId, "0") do
      {:ok, map} ->
        map
      {:error, reason} ->
        %{msg: "Not found", success: false}
    end
  end

  # ---------------------------------------------------
  # This is where you actually ask Redis for the hash "#{match_id}_match"
  # Adapt as needed to your Redis client.
  defp fetch_match_detail_from_redis(match_id) do
    redis_conn = :my_redis
    max_tries = 20
    delay_ms = 300

    do_fetch_match_detail(redis_conn, match_id, max_tries, delay_ms)
  end

  defp do_fetch_match_detail(redis_conn, match_id, try_left, delay_ms) do
    case Redix.command(redis_conn, ["HGETALL", "#{match_id}"]) do
      {:ok, []} ->
        if try_left > 0 do
          Process.sleep(delay_ms)
          do_fetch_match_detail(redis_conn, match_id, try_left - 1, delay_ms)
        else
          IO.puts("Hash '#{match_id}' is empty after retries.")
          %{}
        end

      {:ok, flat_list} when is_list(flat_list) ->
        hash_map =
          flat_list
          |> Enum.chunk_every(2)
          |> Enum.into(%{}, fn [k, v] -> {k, v} end)

        hash_map

      {:error, reason} ->
        IO.puts("Redis HGETALL error: #{inspect(reason)}")
        %{}
    end
  end

  defp fetch_session_detail_from_redis(match_id) do
    redis_conn = :my_redis

    case Redix.command(redis_conn, ["HGETALL", "#{match_id}_session"]) do
      {:ok, %{}} ->
        IO.puts("Hash 'my_hash' is empty or does not exist")

      {:ok, flat_list} when is_list(flat_list) ->
        # flat_list is like ["field1", "value1", "field2", "value2", …]
        hash_map =
          flat_list
          |> Enum.chunk_every(2)
          |> Enum.into(%{}, fn [k, v] -> {k, v} end)

      {:error, reason} ->
        IO.puts("Redis HGETALL error: #{inspect(reason)}")
    end
  end

  @spec manual_prefix(String.t() | nil) :: boolean()
  def manual_prefix(nil), do: false

  def manual_prefix(market_id) when is_binary(market_id) do
    case String.split(market_id, ~r/(\d+)/) do
      [prefix | _rest] -> prefix == "manual"
      _ -> false
    end
  end

  def getCricketData(matchId, marketId, matchData) do
    Logger.debug(matchId)
    alias ThirdpartyWeb.ExternalApis.Match, as: MatchListApi
    alias ThirdpartyWeb.Constant, as: Constant
    matchDetail = matchData

    returnResult = %{
      "id" => matchId,
      "marketId" => marketId,
      "eventId" => matchDetail["eventId"],
      "apiSession" => %{}
    }

    expertResult = %{
      "id" => matchId,
      "marketId" => marketId,
      "eventId" => matchDetail["eventId"],
      "apiSession" => %{}
    }

    isAPISessionActive =
      if matchDetail["apiSessionActive"], do: matchDetail["apiSessionActive"], else: false

    isManualSessionActive =
      if matchDetail["manualSessionActive"], do: matchDetail["manualSessionActive"], else: false

    isManual = manual_prefix(marketId)

    if !isManual do
      customObject = %{"tournament" => []}

      data =
        case MatchListApi.fetch_match_rate(
               if(matchDetail["matchType"] == "cricket", do: "2", else: "3"),
               matchDetail["eventId"]
             ) do
          {:ok, map} ->
            map["data"]

          {:error, other} ->
            Logger.error("Unexpected fetch_match_rate error: #{inspect(other)}")
            []

          other ->
            Logger.error("fetch_match_rate returned an unexpected value: #{inspect(other)}")
            []
        end || []

      # Decode tournament JSON once, rebind matchDetail
      tor =
        case Jason.decode(matchDetail["tournament"] || "{}") do
          {:ok, m} ->
            m

          {:error, reason} ->
            Logger.error("Failed to parse tournament JSON: #{inspect(reason)}")
            %{}
        end

      matchDetail = Map.put(matchDetail, "tournament", tor)
      # 1) Update gmid in both maps
      gmid = get_in(data, [Access.at(0), "gmid"]) || ""
      returnResult = Map.put(returnResult, "gmid", gmid)
      expertResult = Map.put(expertResult, "gmid", gmid)
      # 2) Build customObject by iterating data
      customObject = build_custom_object(matchDetail, data, customObject)

      # 3) If there is any tournament data, build expertResult & returnResult’s “tournament” lists
      otherData = matchDetail["tournament"] || []

      {returnResult, expertResult} =
        if customObject["tournament"] != [] or otherData != [] do
          # Initialize empty lists
          expertResult = Map.put(expertResult, "tournament", [])
          returnResult = Map.put(returnResult, "tournament", [])
          # First, iterate over customObject["tournament"]
          iterated = []

          {iterated, expertResult, returnResult} =
            Enum.reduce(customObject["tournament"], {[], expertResult, returnResult}, fn item,
                                                                                         {iters,
                                                                                          eRes,
                                                                                          rRes} ->
              isRedisExist =
                Enum.find_index(otherData, fn it ->
                  to_string(it["mid"]) == to_string(item["mid"])
                end)

              if isRedisExist != nil and isRedisExist >= 0 do
                parseData = Enum.at(otherData, isRedisExist)

                obj = %{
                  "id" => parseData["id"],
                  "marketId" => parseData["marketId"],
                  "name" => parseData["name"],
                  "minBet" => parseData["minBet"],
                  "maxBet" => parseData["maxBet"],
                  "type" => parseData["type"],
                  "isActive" => parseData["isActive"],
                  "activeStatus" => parseData["activeStatus"],
                  "isManual" => parseData["isManual"],
                  "dbRunner" => parseData["runners"],
                  "gtype" => parseData["gtype"],
                  "exposureLimit" => parseData["exposureLimit"],
                  "betLimit" => parseData["betLimit"],
                  "isCommissionActive" => parseData["isCommissionActive"],
                  "sno" => parseData["sNo"]
                }

                formateData = formateOdds(item, obj)
                # Rebind expertResult
                eRes = Map.put(eRes, "tournament", eRes["tournament"] ++ [formateData])
                # If activeStatus is "live", also add to returnResult
                rRes =
                  if parseData["activeStatus"] == "live" do
                    Map.put(rRes, "tournament", rRes["tournament"] ++ [formateData])
                  else
                    rRes
                  end

                {iters ++ [item["mid"]], eRes, rRes}
              else
                # Rebind expertResult
                formateData = formateOdds(item, %{})

                eRes = Map.put(eRes, "tournament", eRes["tournament"] ++ [formateData])
                {iters, eRes, rRes}
              end
            end)

          # Next, iterate over otherData for any items not already in `iterated`
          {returnResult, expertResult} =
            Enum.reduce(otherData, {returnResult, expertResult}, fn item, {rResAcc, eResAcc} ->
              if item["activeStatus"] != "close" do
                already =
                  Enum.find_index(iterated, fn it -> to_string(it) == to_string(item["mid"]) end)

                if already == nil or already < 0 do
                  isTwoTeam = length(item["runners"] || []) == 2

                  obj = %{
                    "id" => item["id"],
                    "marketId" => item["marketId"],
                    "name" => item["name"],
                    "minBet" => item["minBet"],
                    "maxBet" => item["maxBet"],
                    "type" => item["type"],
                    "isActive" => item["isActive"],
                    "activeStatus" => item["activeStatus"],
                    "isCommissionActive" => item["isCommissionActive"],
                    "sno" => item["sNo"],
                    "parentBetId" => item["parentBetId"],
                    "isManual" => item["isManual"],
                    "runners" =>
                      if item["isManual"] do
                        Enum.map(item["runners"] || [], fn runner ->
                          %{
                            "selectionId" => runner["selectionId"],
                            "status" => String.upcase(runner["status"]),
                            "nat" => runner["runnerName"],
                            "id" => runner["id"],
                            "sortPriority" => runner["sortPriority"],
                            "parentRunnerId" => runner["parentRunnerId"],
                            "ex" => %{
                              "availableToBack" => [
                                %{
                                  "price" =>
                                    if runner["backRate"] > 2 do
                                      if isTwoTeam and runner["backRate"] > 100 do
                                        0
                                      else
                                        trunc(:math.floor(runner["backRate"])) - 2
                                      end
                                    else
                                      0
                                    end,
                                  "otype" => "back",
                                  "oname" => "back3",
                                  "tno" => 2
                                },
                                %{
                                  "price" =>
                                    if runner["backRate"] > 1 do
                                      if isTwoTeam and runner["backRate"] > 100 do
                                        0
                                      else
                                        trunc(:math.floor(runner["backRate"])) - 1
                                      end
                                    else
                                      0
                                    end,
                                  "otype" => "back",
                                  "oname" => "back2",
                                  "tno" => 1
                                },
                                %{
                                  "price" =>
                                    if runner["backRate"] < 0 do
                                      0
                                    else
                                      runner["backRate"]
                                    end,
                                  "otype" => "back",
                                  "oname" => "back1",
                                  "tno" => 0
                                }
                              ],
                              "availableToLay" => [
                                %{
                                  "price" =>
                                    if runner["layRate"] < 0 do
                                      0
                                    else
                                      runner["layRate"]
                                    end,
                                  "otype" => "lay",
                                  "oname" => "lay1",
                                  "tno" => 0
                                },
                                %{
                                  "price" =>
                                    if isTwoTeam and runner["layRate"] > 100 do
                                      0
                                    else
                                      if (!matchDetail["rateThan100"] and
                                            runner["layRate"] > 99.99) or
                                           runner["layRate"] <= 0 do
                                        0
                                      else
                                        trunc(:math.floor(runner["layRate"])) + 1
                                      end
                                    end,
                                  "otype" => "lay",
                                  "oname" => "lay2",
                                  "tno" => 1
                                },
                                %{
                                  "price" =>
                                    if isTwoTeam and runner["layRate"] > 100 do
                                      0
                                    else
                                      if (!matchDetail["rateThan100"] and
                                            runner["layRate"] > 98.99) or
                                           runner["layRate"] <= 0 do
                                        0
                                      else
                                        trunc(:math.floor(runner["layRate"])) + 2
                                      end
                                    end,
                                  "otype" => "lay",
                                  "oname" => "lay3",
                                  "tno" => 2
                                }
                              ]
                            }
                          }
                        end)
                      else
                        Enum.map(item["runners"] || [], fn run ->
                          %{
                            "nat" => run["runnerName"],
                            "id" => run["id"],
                            "selectionId" => run["selectionId"],
                            "sortPriority" => run["sortPriority"]
                          }
                        end)
                      end
                  }

                  formateData = formateOdds(item, obj)

                  rResAcc = Map.put(rResAcc, "tournament", [formateData | rResAcc["tournament"]])
                  eResAcc = Map.put(eResAcc, "tournament", [formateData | eResAcc["tournament"]])
                  returnResult = rResAcc
                  {rResAcc, eResAcc}
                else
                  returnResult = rResAcc
                  {rResAcc, eResAcc}
                end
              else
                returnResult = rResAcc
                {rResAcc, eResAcc}
              end
            end)

          {returnResult, expertResult}
        end

      {sessionApiObj, manualSessionObj} =
        if isAPISessionActive || isManualSessionActive do
          sessionData = fetch_session_detail_from_redis(matchDetail["id"])
          sessionData = Map.values(sessionData || %{})
          apiResult = %{}
          manualResult = []

          {apiResult, manualResult} =
            Enum.reduce(sessionData, {%{}, []}, fn item, {apiAcc, manualAcc} ->
              parseObj =
                case Jason.decode(item) do
                  {:ok, m} ->
                    m

                  {:error, reason} ->
                    Logger.error("Failed to parse session JSON: #{inspect(reason)}")
                    %{}
                end

              if parseObj["isManual"] do
                manualAcc = [parseObj | manualAcc]
                {apiAcc, manualAcc}
              else
                type = parseObj["type"] || "unknown"

                apiAcc =
                  Map.update(apiAcc, type, [parseObj], fn existing ->
                    [parseObj | existing]
                  end)

                {apiAcc, manualAcc}
              end
            end)

          {apiResult, manualResult}
        else
          {%{}, []}
        end

      {returnResult, expertResult} =
        if isAPISessionActive do
          keys = ["session", "overByover", "ballByBall", "oddEven", "fancy1", "khado", "meter"]

          {returnResult, expertResult} =
            Enum.reduce(keys, {returnResult, expertResult}, fn key,
                                                               {returnResult, expertResult} ->
              if customObject[key] || sessionApiObj[key] do
                %{"returnResult" => returnRes, "expertResult" => expertRes} =
                  formatSessionMarket(key, customObject, sessionApiObj)

                returnResult =
                  Map.update(returnResult, "apiSession", %{key => returnRes}, fn api_map ->
                    Map.put(api_map, key, returnRes)
                  end)

                expertResult =
                  Map.update(expertResult, "apiSession", %{key => expertRes}, fn api_map ->
                    Map.put(api_map, key, expertRes)
                  end)

                {returnResult, expertResult}
              else
                {returnResult, expertResult}
              end
            end)

          key = "cricketCasino"

          {returnResult, expertResult} =
            if customObject[key] || sessionApiObj[key] do
              %{"returnResult" => returnRes, "expertResult" => expertRes} =
                formatCricketCasinoMarket(key, customObject, sessionApiObj)

              returnResult =
                Map.update(returnResult, "apiSession", %{key => returnRes}, fn api_map ->
                  Map.put(api_map, key, returnRes)
                end)

              expertResult =
                Map.update(expertResult, "apiSession", %{key => expertRes}, fn api_map ->
                  Map.put(api_map, key, expertRes)
                end)

              {returnResult, expertResult}
            else
              {returnResult, expertResult}
            end

          {returnResult, expertResult}
        else
          {returnResult, expertResult}
        end

      {returnResult, expertResult} =
        if isManualSessionActive do
          returnResult =
            Map.put(
              returnResult,
              "sessionBettings",
              Enum.filter(manualSessionObj, fn item ->
                item["activeStatus"] == "live"
              end)
            )

          key = "manualSession"

          %{"expertResult" => expertResult1} =
            formatSessionMarket(key, %{}, %{
              key => manualSessionObj
            })

          expertResult =
            Map.update(expertResult, "apiSession", %{key => expertResult1}, fn api_map ->
              Map.put(api_map, key, expertResult1)
            end)

          {returnResult, expertResult}
        else
          {returnResult, expertResult}
        end

      # At this point, returnResult and expertResult have all the tournament entries
      # Finally, return returnResult from this function
      {returnResult, expertResult}
    else
      # If isManual is true, we do nothing and just return the original “blank” map
      {returnResult, expertResult}
    end
  end

  defp formateOdds(data, redisData) do
    %{
      "marketId" => data["marketId"],
      "mid" => data["mid"] || redisData["marketId"],
      "gmid" => data["gmid"],
      "status" => data["status"],
      "inplay" => data["inplay"],
      "gtype" => redisData["gtype"] || data["gtype"],
      "rem" => data["rem"],
      "isManual" => redisData["isManual"] || data["isManual"],
      "exposureLimit" => redisData["exposureLimit"],
      "isCommissionActive" => redisData["isCommissionActive"],
      "sno" => data["sno"] || redisData["sno"],
      "parentBetId" => redisData["parentBetId"],
      "runners" =>
        if is_list(data["section"]) do
          data["section"]
          |> Enum.map(fn item ->
            %{
              "selectionId" => item["sid"],
              "status" => item["gstatus"],
              "nat" => item["nat"],
              "sortPriority" => item["sno"],
              "id" =>
                redisData["dbRunner"]
                |> Kernel.||([])
                |> Enum.find(fn runner ->
                  to_string(runner["selectionId"]) == to_string(item["sid"])
                end)
                |> case do
                  nil -> nil
                  runner -> runner["id"]
                end,
              "ex" => %{
                "availableToBack" =>
                  (item["odds"] || [])
                  |> Enum.filter(fn odd -> odd["otype"] == "back" end)
                  |> Enum.map(fn odd ->
                    %{
                      "price" => odd["odds"],
                      "size" => odd["size"],
                      "otype" => odd["otype"],
                      "oname" => odd["oname"],
                      "tno" => odd["tno"]
                    }
                  end),
                "availableToLay" =>
                  (item["odds"] || [])
                  |> Enum.filter(fn odd -> odd["otype"] != "back" end)
                  |> Enum.map(fn odd ->
                    %{
                      "price" => odd["odds"],
                      "size" => odd["size"],
                      "otype" => odd["otype"],
                      "oname" => odd["oname"],
                      "tno" => odd["tno"]
                    }
                  end)
              }
            }
            |> Enum.reject(fn {_k, v} -> is_nil(v) end)
            |> Enum.into(%{})
          end)
        else
          redisData["runners"] || []
        end,
      "id" => redisData["id"],
      "name" => redisData["name"] || data["mname"],
      "minBet" => redisData["minBet"] || data["min"],
      "maxBet" => redisData["maxBet"] || data["max"],
      "type" => redisData["type"],
      "isActive" => redisData["isActive"],
      "activeStatus" => redisData["activeStatus"],
      "betLimit" => redisData["betLimit"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end

  defp formatSessionMarket(key, data, redisData) do
    result = data[key]
    expertSession = []
    onlyLiveSession = []
    addedSession = []

    currRedisData = redisData[key] || %{}

    {onlyLiveSession, addedSession, expertSession} =
      if(result != nil) do
        # initialize with your three variables as empty lists
        initial_acc = {[], [], []}

        {onlyLiveSession, addedSession, expertSession} =
          Enum.reduce(result["section"] || [], initial_acc, fn session,
                                                               {onlyLiveSession, addedSession,
                                                                expertSession} ->
            # 1) format the session
            sessionObj = format_session(session)

            # 2) find matching index in currRedisData
            sessionIndex =
              Enum.find_index(currRedisData, fn x ->
                to_string(x["selectionId"]) == to_string(sessionObj["SelectionId"])
              end)

            # 3) if found, enrich sessionObj
            sessionObj =
              if is_integer(sessionIndex) and sessionIndex >= 0 do
                redisMap = Enum.at(currRedisData, sessionIndex)

                sessionObj
                |> Map.put("id", redisMap["id"])
                |> Map.put("activeStatus", redisMap["activeStatus"])
                |> Map.put("min", redisMap["min"])
                |> Map.put("max", redisMap["max"])
                |> Map.put("createdAt", redisMap["createdAt"])
                |> Map.put("updatedAt", redisMap["updatedAt"])
                |> Map.put("exposureLimit", redisMap["exposureLimit"])
                |> Map.put("isCommissionActive", redisMap["isCommissionActive"])
              else
                sessionObj
              end

            # 4) build onlyLiveSession: prepend if live
            onlyLiveSession =
              if sessionObj["activeStatus"] == "live" do
                [sessionObj | onlyLiveSession]
              else
                onlyLiveSession
              end

            # 5) always prepend to addedSession and expertSession
            addedSession = [sessionObj["SelectionId"] | addedSession]
            expertSession = [sessionObj | expertSession]

            # return the updated tuple for the next iteration
            {onlyLiveSession, addedSession, expertSession}
          end)

        {onlyLiveSession, addedSession, expertSession}
      else
        {[], [], []}
      end

    {onlyLiveSession, expertSession} =
      Enum.reduce(currRedisData, {onlyLiveSession, expertSession}, fn session,
                                                                      {onlyLiveSession,
                                                                       expertSession} ->
        selection_id = session["selectionId"]

        # only proceed if we haven't already added this selection
        already_present =
          Enum.find(addedSession, fn id ->
            to_string(id) == to_string(selection_id)
          end)

        obj =
          if already_present == nil do
            # build your base obj (if manual, apply your formatting logic)
            obj =
              if session["isManual"] do
                session
                |> Map.put("nat", session["name"])
                |> Map.put("gstatus", session["status"])
                |> Map.put("odds", [
                  %{
                    "odds" => session["yesRate"],
                    "otype" => "back",
                    "oname" => "back1",
                    "tno" => 0,
                    "size" => session["yesPercent"]
                  },
                  %{
                    "odds" => session["noRate"],
                    "otype" => "lay",
                    "oname" => "lay1",
                    "tno" => 0,
                    "size" => session["noPercent"]
                  }
                ])
                |> format_session()
              else
                %{}
              end
              |> Map.put("SelectionId", selection_id)
              |> Map.put("RunnerName", session["name"])
              |> Map.put("min", session["minBet"])
              |> Map.put("max", session["maxBet"])
              |> Map.put("id", session["id"])
              |> Map.put("activeStatus", session["activeStatus"])
              |> Map.put("createdAt", session["createdAt"])
              |> Map.put("updatedAt", session["updatedAt"])
              |> Map.put("exposureLimit", session["exposureLimit"])
              |> Map.put("isCommissionActive", session["isCommissionActive"])

            # if it's live, prepend to onlyLiveSession
            onlyLiveSession =
              if obj["activeStatus"] == "live" do
                [obj | onlyLiveSession]
              else
                onlyLiveSession
              end

            # always prepend to expertSession and addedSession
            expertSession = [obj | expertSession]

            {onlyLiveSession, expertSession}
          else
            # already seen this selectionId → no change
            {onlyLiveSession, expertSession}
          end
      end)

    %{
      "returnResult" => %{
        "mname" => result["mname"],
        "rem" => result["rem"],
        "mid" => result["mid"],
        "gtype" => result["gtype"] || Enum.at(currRedisData, 0)["gtype"],
        "status" => result["status"],
        "section" => Enum.reverse(onlyLiveSession)
      },
      "expertResult" => %{
        "mname" => result["mname"],
        "rem" => result["rem"],
        "mid" => result["mid"],
        "gtype" => result["gtype"] || Enum.at(currRedisData, 0)["gtype"],
        "status" => result["status"],
        "section" => Enum.reverse(expertSession)
      }
    }
  end

  defp formatCricketCasinoMarket(key, data, redisData) do
    result = data[key]
    expertSession = []
    onlyLiveSession = []
    addedSession = []

    currRedisData = redisData[key] || %{}

    {onlyLiveSession, addedSession, expertSession} =
      if(result != nil) do
        # initialize with your three variables as empty lists
        initial_acc = {[], [], []}

        {onlyLiveSession, addedSession, expertSession} =
          Enum.reduce(result || [], initial_acc, fn session,
                                                    {onlyLiveSession, addedSession, expertSession} ->
            # 1) format the session
            sessionObj = %{
              "SelectionId" => to_string(session["mid"]),
              "RunnerName" => session["mname"],
              "gtype" => session["gtype"],
              "section" => session["section"],
              "GameStatus" => session["status"],
              "rem" => session["rem"],
              "mid" => session["mid"]
            }

            # 2) find matching index in currRedisData
            sessionIndex =
              Enum.find_index(currRedisData, fn x ->
                to_string(x["selectionId"]) == to_string(sessionObj["SelectionId"])
              end)

            # 3) if found, enrich sessionObj
            sessionObj =
              if is_integer(sessionIndex) and sessionIndex >= 0 do
                redisMap = Enum.at(currRedisData, sessionIndex)

                sessionObj
                |> Map.put("id", redisMap["id"])
                |> Map.put("activeStatus", redisMap["activeStatus"])
                |> Map.put("min", redisMap["min"])
                |> Map.put("max", redisMap["max"])
                |> Map.put("createdAt", redisMap["createdAt"])
                |> Map.put("updatedAt", redisMap["updatedAt"])
                |> Map.put("exposureLimit", redisMap["exposureLimit"])
                |> Map.put("isCommissionActive", redisMap["isCommissionActive"])
              else
                sessionObj
              end

            # 4) build onlyLiveSession: prepend if live
            onlyLiveSession =
              if sessionObj["activeStatus"] == "live" do
                [sessionObj | onlyLiveSession]
              else
                onlyLiveSession
              end

            # 5) always prepend to addedSession and expertSession
            addedSession = [sessionObj["SelectionId"] | addedSession]
            expertSession = [sessionObj | expertSession]

            # return the updated tuple for the next iteration
            {Enum.reverse(onlyLiveSession), Enum.reverse(addedSession),
             Enum.reverse(expertSession)}
          end)

        {onlyLiveSession, addedSession, expertSession}
      else
        {[], [], []}
      end

    Enum.map(currRedisData, fn session ->
      if(List.keyfind(addedSession, to_string(session["selectionId"]), 0) == nil) do
        obj = %{}

        obj = Map.put(obj, "SelectionId", to_string(session["selectionId"]))
        obj = Map.put(obj, "RunnerName", session["name"])
        obj = Map.put(obj, "min", session["minBet"])
        obj = Map.put(obj, "max", session["maxBet"])
        obj = Map.put(obj, "id", session["id"])
        obj = Map.put(obj, "activeStatus", session["activeStatus"])
        obj = Map.put(obj, "createdAt", session["createdAt"])
        obj = Map.put(obj, "updatedAt", session["updatedAt"])
        obj = Map.put(obj, "exposureLimit", session["exposureLimit"])
        obj = Map.put(obj, "isCommissionActive", session["isCommissionActive"])

        if obj["activeStatus"] == "live" do
          onlyLiveSession = [obj | onlyLiveSession]
        end

        expertSession = [obj | expertSession]
      end
    end)

    %{
      "returnResult" => %{
        # "mname" => result["mname"],
        # "rem" => result["rem"],
        # "mid" => result["mid"],
        # "gtype" => result["gtype"] || currRedisData[0]["gtype"],
        # "status" => result["status"],
        "section" => onlyLiveSession
      },
      "expertResult" => %{
        # "mname" => result["mname"],
        # "rem" => result["rem"],
        # "mid" => result["mid"],
        # "gtype" => result["gtype"] || currRedisData[0]["gtype"],
        # "status" => result["status"],
        "section" => expertSession
      }
    }
  end

  def format_session(session) do
    %{
      "SelectionId" => to_string(session["sid"]),
      "RunnerName" => session["nat"],
      "ex" => %{
        "availableToBack" =>
          session["odds"]
          |> Enum.filter(fn odd -> odd["otype"] == "back" end)
          |> Enum.map(fn odd ->
            %{
              "price" => odd["odds"],
              "size" => odd["size"],
              "otype" => odd["otype"],
              "oname" => odd["oname"],
              "tno" => odd["tno"]
            }
          end),
        "availableToLay" =>
          session["odds"]
          |> Enum.filter(fn odd -> odd["otype"] != "back" end)
          |> Enum.map(fn odd ->
            %{
              "price" => odd["odds"],
              "size" => odd["size"],
              "otype" => odd["otype"],
              "oname" => odd["oname"],
              "tno" => odd["tno"]
            }
          end)
      },
      "GameStatus" => session["gstatus"],
      "rem" => session["rem"]
    }
  end

  def build_custom_object(match_detail, data, initial) do
    if is_nil(match_detail["teamB"]) do
      # “no teamB” branch
      Enum.reduce(data, initial, fn match, acc ->
        case match["gtype"] do
          x when x in ["match", "match1"] ->
            # prepend onto the existing "tournament" list (or start a new list if missing)
            Map.update(acc, "tournament", [match], fn existing -> [match | existing] end)

          "fancy" ->
            Map.put(acc, "session", match)

          "oddeven" ->
            Map.put(acc, "oddEven", match)

          "fancy1" ->
            Map.put(acc, "fancy1", match)

          _ ->
            acc
        end
      end)
    else
      # “has teamB” branch
      Enum.reduce(data, initial, fn match, acc ->
        # normalize mname to lowercase (guards against nil)
        name = String.downcase(match["mname"] || "")

        case name do
          "normal" ->
            Map.put(acc, "session", match)

          "over by over" ->
            Map.put(acc, "overByover", match)

          "ball by ball" ->
            Map.put(acc, "ballByBall", match)

          "oddeven" ->
            Map.put(acc, "oddEven", match)

          "fancy1" ->
            Map.put(acc, "fancy1", match)

          "khado" ->
            Map.put(acc, "khado", match)

          "meter" ->
            Map.put(acc, "meter", match)

          _ ->
            # anything else ⇒ inspect gtype instead
            cond do
              match["gtype"] == "cricketcasino" ->
                Map.update(acc, "cricketCasino", [match], fn existing -> [match | existing] end)

              match["gtype"] in ["match", "match1"] ->
                Map.update(acc, "tournament", [match], fn existing -> [match | existing] end)

              true ->
                acc
            end
        end
      end)
    end
  end

  defp lookup_rate(match_id) do
    case :ets.lookup(:match_rates, match_id) do
      [{^match_id, rate}] -> rate
      _ -> nil
    end
  end

  def via(match_id) do
    {:via, Registry, {Thirdparty.MatchIntervalManager.Registry, match_id}}
  end

  def increment_listener(server_pid) do
    GenServer.cast(server_pid, :increment)
  end

  def decrement_listener(server_pid) do
    GenServer.cast(server_pid, :decrement)
  end

  @impl true
  def terminate(_reason, state) do
    # Clean up timer
    if state.timer_ref, do: :timer.cancel(state.timer_ref)
    Logger.debug("Stopped interval for match: #{state.match_id}")
    :ok
  end
end
