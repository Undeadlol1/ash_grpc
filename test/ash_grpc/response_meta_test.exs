defmodule AshGrpc.ResponseMetaTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.GrpcServer, only: [signed_in: 2, start: 1]
  import ExUnit.CaptureLog

  alias AshGrpc.TestSupport.Endpoint, as: PlainEndpoint
  alias AshGrpc.TestSupport.MetaEndpoint
  alias AshGrpc.TestSupport.MetaEndpoint.Blog.V1
  alias AshGrpc.TestSupport.MetaEndpoint.Blog.V1.Posts.Server
  alias AshGrpc.TestSupport.MetaEndpoint.Blog.V1.Posts.Stub
  alias GRPC.RPCError
  alias GRPC.Status

  setup do
    %{channel: start(MetaEndpoint), author: "author#{System.unique_integer([:positive])}"}
  end

  defp create(channel, author, headers) do
    Stub.create_post(channel, %V1.CreatePostRequest{title: "Meta"},
      metadata: signed_in(author, headers)
    )
  end

  test "the rendered proto has meta = 2 on every response only when the option is on" do
    [{_path, with_meta}] = AshGrpc.Proto.render(MetaEndpoint)
    [{_path, without_meta}] = AshGrpc.Proto.render(PlainEndpoint)

    assert with_meta =~
             "message CreatePostResponse {\n  Post result = 1;\n  optional string meta = 2;\n}"

    responses = Regex.scan(~r/message \w+Response \{/, with_meta)
    assert length(Regex.scan(~r/optional string meta = 2;/, with_meta)) == length(responses)
    refute without_meta =~ "meta"
  end

  test "adding meta is a compatible change" do
    [{_path, with_meta}] = AshGrpc.Proto.render(MetaEndpoint)
    [{_path, without_meta}] = AshGrpc.Proto.render(PlainEndpoint)

    assert AshGrpc.Proto.Compatibility.check(without_meta, with_meta) == :ok
  end

  test "the generated response module carries meta", %{channel: channel, author: author} do
    assert {:ok, %V1.CreatePostResponse{meta: meta}} = create(channel, author, %{})
    assert Jason.decode!(meta)["outer"] == 1
  end

  test "interceptors merge their meta, the later one winning a shared key", %{
    channel: channel,
    author: author
  } do
    assert {:ok, %{meta: meta}} = create(channel, author, %{})

    assert Jason.decode!(meta) == %{"outer" => 1, "inner" => 1, "shared" => "inner"}
  end

  test "meta set around a list read arrives too", %{channel: channel, author: author} do
    assert {:ok, %V1.ListPostsResponse{meta: meta}} =
             Stub.list_posts(channel, %V1.ListPostsRequest{}, metadata: signed_in(author, %{}))

    assert Jason.decode!(meta)["inner"] == 1
  end

  test "a 100 KB meta arrives intact", %{channel: channel, author: author} do
    assert {:ok, %{meta: meta}} = create(channel, author, %{"x-meta-bytes" => "100000"})

    assert Jason.decode!(meta)["inner"] == String.duplicate("x", 100_000)
  end

  test "unicode text arrives intact", %{channel: channel, author: author} do
    assert {:ok, %{meta: meta}} = create(channel, author, %{"x-meta-text" => "1"})

    assert Jason.decode!(meta)["inner"] == "Привет, мир ✓"
  end

  test "a call nobody put meta on has none", %{channel: channel, author: author} do
    assert {:ok, %{meta: nil}} = create(channel, author, %{"x-no-meta" => "1"})
  end

  test "a generic action under a deadline still gets its meta", %{author: author} do
    stream = %GRPC.Server.Stream{
      endpoint: MetaEndpoint,
      deadline: System.monotonic_time(:millisecond) + 5_000,
      http_request_headers: signed_in(author, %{})
    }

    next = fn request, stream ->
      AshGrpc.Endpoint.put_response_meta(stream, fn -> %{"late" => true} end)
      Server.nap(request, stream)
    end

    assert %V1.NapResponse{meta: ~s({"late":true})} =
             AshGrpc.Authenticator.Interceptor.call(
               %V1.NapRequest{},
               stream,
               next,
               AshGrpc.TestSupport.Authenticator
             )
  end

  test "an errored call answers with its status alone", %{
    channel: channel,
    author: author
  } do
    capture_log(fn ->
      assert {:error, %RPCError{status: status, message: message}} =
               Stub.explode(channel, %V1.ExplodeRequest{}, metadata: signed_in(author, %{}))

      assert status == Status.internal()
      assert message == "Internal error"
    end)
  end

  test "putting meta on an endpoint without the option raises" do
    stream = %GRPC.Server.Stream{endpoint: PlainEndpoint}

    assert_raise ArgumentError, ~r/response_meta: true/, fn ->
      AshGrpc.Endpoint.put_response_meta(stream, %{})
    end
  end
end
