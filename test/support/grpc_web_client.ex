defmodule AshGrpc.TestSupport.GrpcWebClient do
  @moduledoc false

  def call(port, method, path, headers, body \\ "") do
    {:ok, conn} = :gun.open(~c"127.0.0.1", port, %{protocols: [:http2]})
    {:ok, :http2} = :gun.await_up(conn)
    ref = :gun.request(conn, method, path, Enum.to_list(headers), body)
    {:response, fin, status, response_headers} = :gun.await(conn, ref)
    {data, trailers} = read_body(conn, ref, fin)
    :gun.close(conn)
    %{status: status, headers: Map.new(response_headers), body: data, trailers: Map.new(trailers)}
  end

  def post(port, path, headers, message) do
    headers = Map.merge(%{"content-type" => "application/grpc-web+proto"}, headers)
    call(port, "POST", path, headers, frame(message))
  end

  def open_stream(port, path, headers, message) do
    {:ok, conn} = :gun.open(~c"127.0.0.1", port, %{protocols: [:http2]})
    {:ok, :http2} = :gun.await_up(conn)

    headers =
      Map.merge(%{"content-type" => "application/grpc+proto", "te" => "trailers"}, headers)

    stream = :gun.request(conn, "POST", path, Enum.to_list(headers), frame(message))
    {:response, :nofin, 200, _headers} = :gun.await(conn, stream)
    {:data, :nofin, _first_message} = :gun.await(conn, stream)
    {conn, stream}
  end

  def frame(message) do
    payload = message.__struct__.encode(message)
    <<0, byte_size(payload)::32, payload::binary>>
  end

  def data_frame(module, body) do
    <<0, size::32, payload::binary-size(size), _rest::binary>> = body
    module.decode(payload)
  end

  def trailer_frame(body) do
    <<0x80, size::32, trailers::binary-size(size)>> = last_frame(body)

    trailers
    |> String.split("\r\n", trim: true)
    |> Map.new(fn line ->
      [key, value] = String.split(line, ": ", parts: 2)
      {key, value}
    end)
  end

  defp last_frame(<<0x80, _::binary>> = trailer), do: trailer

  defp last_frame(<<0, size::32, _message::binary-size(size), rest::binary>>),
    do: last_frame(rest)

  defp read_body(_conn, _ref, :fin), do: {"", []}

  defp read_body(conn, ref, :nofin) do
    case :gun.await_body(conn, ref) do
      {:ok, data} -> {data, []}
      {:ok, data, trailers} -> {data, trailers}
    end
  end
end
