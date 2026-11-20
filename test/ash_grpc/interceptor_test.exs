defmodule AshGrpc.InterceptorTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.GrpcServer, only: [signed_in: 2, start: 1]

  alias AshGrpc.TestSupport.InterceptedEndpoint
  alias AshGrpc.TestSupport.InterceptedEndpoint.Blog.V1
  alias AshGrpc.TestSupport.InterceptedEndpoint.Blog.V1.Posts.Stub
  alias GRPC.RPCError
  alias GRPC.Status

  setup do
    %{channel: start(InterceptedEndpoint), author: "author#{System.unique_integer([:positive])}"}
  end

  defp watched(extra \\ %{}) do
    "#PID" <> pid = inspect(self())
    Map.put(extra, "x-test-pid", pid)
  end

  defp create(channel, metadata, opts \\ []) do
    Stub.create_post(
      channel,
      %V1.CreatePostRequest{title: "Intercepted"},
      [metadata: metadata] ++ opts
    )
  end

  test "interceptors run in declaration order around the action, after authentication", %{
    channel: channel,
    author: author
  } do
    assert {:ok, _reply} = create(channel, signed_in(author, watched()))

    assert interceptor_events() == [
             {:before, "outer"},
             {:before, "inner"},
             {:after, "inner"},
             {:after, "outer"}
           ]

    assert_received {:opts, "outer", {:ok, outer_opts}}
    assert outer_opts[:actor] == %{name: author, role: :member}
    assert outer_opts[:tenant] == "acme"
  end

  test "request metadata reaches the interceptor and the action runs in its process", %{
    channel: channel,
    author: author
  } do
    assert {:ok, %{result: post}} =
             create(channel, signed_in(author, watched(%{"x-echo" => "hello"})))

    assert post.body == "hello via inner"
  end

  test "trailers set after the action reach the client, the last call winning", %{
    channel: channel,
    author: author
  } do
    assert {:ok, %{result: post}, %{trailers: trailers}} =
             create(channel, signed_in(author, %{"x-echo" => "back"}), return_headers: true)

    assert post.title == "Intercepted"
    assert trailers["x-seen-by"] == "back via outer"
  end

  test "an interceptor that rejects stops the call before the action", %{
    channel: channel,
    author: author
  } do
    assert {:error, %RPCError{status: status, message: message}} =
             create(channel, signed_in(author, watched(%{"x-reject" => "outer"})))

    assert status == Status.failed_precondition()
    assert message == "Rejected by outer"
    assert interceptor_events() == [{:before, "outer"}]

    assert {:ok, %{result: []}} =
             Stub.list_posts(channel, %V1.ListPostsRequest{}, metadata: signed_in(author, %{}))
  end

  test "an unauthenticated call reaches no interceptor", %{channel: channel} do
    assert {:error, %RPCError{status: status}} = create(channel, watched())

    assert status == Status.unauthenticated()
    assert interceptor_events() == []
  end

  defp interceptor_events do
    receive do
      {:before, name} -> [{:before, name} | interceptor_events()]
      {:after, name} -> [{:after, name} | interceptor_events()]
    after
      0 -> []
    end
  end
end
