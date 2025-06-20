defmodule ThirdpartyWeb.Constant do
  @gameType %{
    "football" => 1,
    "tennis" => 2,
    "golf" => 3,
    "cricket" => 4,
    "boxing" => 6,
    "horseRacing" => 7,
    "greyhoundRacing" => 4339,
    "politics" => 5
  }

  @apiEndPoints %{
    "matchOdd" => %{
      "0" => "http://3.11.199.42:3200/matchOddsNew/",
      "1" => "https://betfair.openapi.live/api/v2/listMarketBookOdds?market_id=",
      "2" => "https://devserviceapi.fairgame.club/getAllRateCricket/",
      "3" => "https://devserviceapi.fairgame.club/getAllRateFootBallTennis/"
    },
    "sportListEndPoint" => %{
      "4" => "https://marketsarket.qnsports.live/cricketmatches",
      "1" => "https://marketsarket.qnsports.live/getsoccerallmatches2",
      "2" => "https://marketsarket.qnsports.live/gettennisallmatches2"
    },
    "scoreCardEndPoint" => %{
      "0" => "https://devserviceapi.fairgame.club/cricketScore?eventId="
    },
    "ScoreIframeUrl" => "http://172.105.54.97:8085/api/v2/graphanim?sportid=",
    "tvIframeUrl" => "http://172.105.54.97:8085/api/v2/GetDtvurl?sportid="
  }

  def game_type, do: @gameType
  def api_end_points, do: @apiEndPoints

end
