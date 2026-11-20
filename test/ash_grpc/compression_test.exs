defmodule AshGrpc.CompressionTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.GrpcServer, only: [signed_in: 1, start: 2]

  alias AshGrpc.TestSupport.CompressedEndpoint
  alias AshGrpc.TestSupport.CompressedEndpoint.Blog.V1
  alias AshGrpc.TestSupport.CompressedEndpoint.Blog.V1.Posts.Stub
  alias AshGrpc.TestSupport.Endpoint
  alias GRPC.Compressor.Gzip

  defp create_then_list(endpoint, channel_opts) do
    channel = start(endpoint, channel_opts)
    metadata = signed_in("author#{System.unique_integer([:positive])}")

    {:ok, _created} =
      Stub.create_post(channel, %V1.CreatePostRequest{title: "Squeezed"}, metadata: metadata)

    {:ok, reply, %{headers: headers}} =
      Stub.list_posts(channel, %V1.ListPostsRequest{}, metadata: metadata, return_headers: true)

    {reply, headers}
  end

  test "an endpoint with gzip answers a gzip client with a gzip-encoded response it can read" do
    {reply, headers} = create_then_list(CompressedEndpoint, compressor: Gzip)

    assert headers["grpc-encoding"] == "gzip"
    assert Enum.map(reply.result, & &1.title) == ["Squeezed"]
  end

  test "an endpoint without compressors answers a client that accepts gzip uncompressed" do
    {reply, headers} = create_then_list(Endpoint, accepted_compressors: [Gzip])

    refute Map.has_key?(headers, "grpc-encoding")
    assert Enum.map(reply.result, & &1.title) == ["Squeezed"]
  end
end
