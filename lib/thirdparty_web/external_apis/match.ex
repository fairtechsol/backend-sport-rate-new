require Logger

defmodule ThirdpartyWeb.ExternalApis.Match do
  @finch Thirdparty.Finch
  alias Finch.Response
  alias ThirdpartyWeb.Constant, as: Constant

  @spec fetch_match_list(Integer) :: {:ok, map()} | {:error, term()}
  def fetch_match_list(type) when is_integer(type) do
    try do
      url = Constant.api_end_points()["sportListEndPoint"][Integer.to_string(type)]

      # Build a GET request
      Finch.build(:get, url)
      |> Finch.request(@finch)
      |> handle_response()
    rescue
      e in RuntimeError ->
        IO.puts("Caught runtime error: #{e.message}")

      # You can also catch all with `e in [AnyException, AnotherException]`
      e in _ ->
        IO.puts("Caught some exception: #{inspect(e)}")
    end
  end

  @spec fetch_match_rate(String, any()) :: {:ok, map()} | {:error, term()}
  def fetch_match_rate(type \\ "2", eventId) do
    try do
      url = "#{Constant.api_end_points()["matchOdd"][type]}#{eventId}"

      # Build a GET request
      Finch.build(:get, url)
      |> Finch.request(@finch)
      |> handle_response()
    rescue
      e in RuntimeError ->
        {:error, "Some error occured"}
        IO.puts("Caught runtime error: #{e.message}")

      # You can also catch all with `e in [AnyException, AnotherException]`
      e in _ ->
        {:error, "Some error occured"}
        IO.puts("Caught some exception: #{inspect(e)}")
    end
  end

  @spec get_score_card(any(), String) :: {:ok, map()} | {:error, term()}
  def get_score_card(eventId, type \\ "0") do
    try do
      url = "#{Constant.api_end_points()["scoreCardEndPoint"][type]}#{eventId}"

      # Build a GET request
      Finch.build(:get, url)
      |> Finch.request(@finch)
      |> handle_response()
    rescue
      e in RuntimeError ->
        {:error, "Some error occured"}
        IO.puts("Caught runtime error: #{e.message}")

      # You can also catch all with `e in [AnyException, AnotherException]`
      e in _ ->
        {:error, "Some error occured"}
        IO.puts("Caught some exception: #{inspect(e)}")
    end
  end

  defp handle_response({:ok, %Response{status: 200, body: body}}) do
    try do
      Logger.debug("Response body: #{body}")

      case Jason.decode(body) do
        {:ok, decoded_json} ->
          {:ok, decoded_json}

        {:error, decode_err} when body == "" ->
          # Handle empty body case
          {:ok, ""}

        {:error, decode_err} ->
          {:error, {:json_decode_failed, decode_err}}
      end
    rescue
      e in RuntimeError ->
        IO.puts("Caught runtime error: #{e.message}")

      # You can also catch all with `e in [AnyException, AnotherException]`
      e in _ ->
        IO.puts("Caught some exception: #{inspect(e)}")
    end
  end

  defp handle_response({:ok, %Response{status: status, body: body}}) when status in 400..599 do
    {:error, {:http_error, status, body}}
  end

  defp handle_response({:error, reason}), do: {:error, reason}
end
