defmodule AshGrpc.CorsTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.GrpcServer, only: [signed_in: 2, start: 1]
  import ExUnit.CaptureLog

  alias AshGrpc.TestSupport.CorsEndpoint
  alias AshGrpc.TestSupport.CorsFunctionEndpoint
  alias AshGrpc.TestSupport.Endpoint
  alias AshGrpc.TestSupport.GrpcWebClient

  @origin "https://app.example.com"
  @list_posts "/blog.v1.Posts/ListPosts"
  @unauthenticated "16"

  defp watched(extra \\ %{}) do
    "#PID" <> pid = inspect(self())
    Map.put(extra, "x-test-pid", pid)
  end

  defp list_posts(endpoint, headers) do
    module = Module.concat(endpoint, Blog.V1.ListPostsRequest)

    GrpcWebClient.post(
      port(endpoint),
      @list_posts,
      Map.put(headers, "origin", @origin),
      struct(module)
    )
  end

  defp preflight(endpoint, extra \\ %{}) do
    headers =
      Map.merge(
        %{
          "origin" => @origin,
          "access-control-request-method" => "POST",
          "access-control-request-headers" => "authorization,x-grpc-web,content-type"
        },
        extra
      )

    capture_log(fn ->
      send(
        self(),
        {:response, GrpcWebClient.call(port(endpoint), "OPTIONS", @list_posts, headers)}
      )
    end)

    assert_received {:response, response}
    response
  end

  defp port(endpoint), do: Process.get({:port, endpoint})

  setup do
    for endpoint <- [CorsEndpoint, CorsFunctionEndpoint, Endpoint] do
      channel = start(endpoint)
      Process.put({:port, endpoint}, channel.port)
    end

    %{author: "author#{System.unique_integer([:positive])}"}
  end

  test "a preflight is answered with the allowed origin and the requested headers" do
    response = preflight(CorsEndpoint)

    assert response.status == 200
    assert response.headers["access-control-allow-origin"] == @origin

    assert response.headers["access-control-allow-headers"] ==
             "authorization,x-grpc-web,content-type"
  end

  test "a preflight reaches neither the authenticator nor an action" do
    preflight(CorsEndpoint, watched())

    refute_received {:headers, _headers}
  end

  test "a signed-in gRPC-Web call returns the reply with the CORS headers", %{author: author} do
    response = list_posts(CorsEndpoint, signed_in(author, %{}))

    assert response.status == 200
    assert response.headers["access-control-allow-origin"] == @origin
    reply = GrpcWebClient.data_frame(CorsEndpoint.Blog.V1.ListPostsResponse, response.body)
    assert reply.result == []
    assert GrpcWebClient.trailer_frame(response.body)["grpc-status"] == "0"
  end

  test "a refused call carries the CORS headers and its status in the trailer frame" do
    response = list_posts(CorsEndpoint, watched())

    assert response.headers["access-control-allow-origin"] == @origin
    assert response.status == 200
    refute Map.has_key?(response.headers, "grpc-status")
    trailers = GrpcWebClient.trailer_frame(response.body)
    assert trailers["grpc-status"] == @unauthenticated
    assert trailers["grpc-message"] == "Unauthenticated"
  end

  test "an origin function decides per request", %{author: author} do
    allowed = list_posts(CorsFunctionEndpoint, signed_in(author, %{}))
    assert allowed.headers["access-control-allow-origin"] == @origin

    refused = preflight(CorsFunctionEndpoint, %{"origin" => "http://evil.example"})
    assert refused.headers["access-control-allow-origin"] == "null"
  end

  test "an endpoint without cors sends no CORS headers", %{author: author} do
    signed = list_posts(Endpoint, signed_in(author, %{}))
    refused = list_posts(Endpoint, %{})

    for response <- [signed, refused] do
      refute Map.has_key?(response.headers, "access-control-allow-origin")
    end

    assert GrpcWebClient.trailer_frame(refused.body)["grpc-status"] == @unauthenticated
  end
end
