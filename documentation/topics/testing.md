# Testing

The surest test of an endpoint is a real call over a socket: the same path a
client takes, with the authenticator, interceptors, policies and error mapping
all in play. The library's own tests work this way.

## Start the endpoint on a free port

Port `0` lets the system pick one. Ask `:ranch` which, then connect:

```elixir
defmodule MyAppWeb.GrpcSupport do
  import ExUnit.Callbacks

  def start(endpoint) do
    start_supervised!({endpoint, port: 0})
    port = :ranch.get_port(inspect(endpoint))
    {:ok, channel} = GRPC.Stub.connect("127.0.0.1:#{port}")
    on_exit(fn -> GRPC.Stub.disconnect(channel) end)
    channel
  end

  def signed_in(token, extra \\ %{}) do
    Map.merge(%{"authorization" => "Bearer #{token}"}, extra)
  end
end
```

`start_supervised!` stops the endpoint when the test ends. Tests that share
a data layer such as ETS should not be `async: true`.

## Call it like a client

```elixir
defmodule MyAppWeb.PostsGrpcTest do
  use ExUnit.Case, async: false

  import MyAppWeb.GrpcSupport

  alias MyAppWeb.GrpcEndpoint.Blog.V1
  alias MyAppWeb.GrpcEndpoint.Blog.V1.Posts.Stub

  setup do
    %{channel: start(MyAppWeb.GrpcEndpoint)}
  end

  test "create returns the stored post", %{channel: channel} do
    assert {:ok, %V1.CreatePostResponse{result: post}} =
             Stub.create_post(channel, %V1.CreatePostRequest{title: "Hello"},
               metadata: signed_in("alice")
             )

    assert post.title == "Hello"
  end

  test "no credentials is UNAUTHENTICATED", %{channel: channel} do
    assert {:error, %GRPC.RPCError{status: status}} =
             Stub.list_posts(channel, %V1.ListPostsRequest{})

    assert status == GRPC.Status.unauthenticated()
  end
end
```

Use a test authenticator that accepts a token you choose, or your real one
with a test user. Sending different `metadata` is how you test policies:
the same call as another actor or tenant.

## Check the status and the field violations

```elixir
assert {:error, %GRPC.RPCError{status: status, details: [detail]}} =
         Stub.create_post(channel, %V1.CreatePostRequest{title: "ab"},
           metadata: signed_in("alice")
         )

assert status == GRPC.Status.invalid_argument()

assert %Google.Rpc.BadRequest{field_violations: [%{field: "title"}]} =
         Google.Rpc.BadRequest.decode(detail.value)
```

An internal error logs its cause. Wrap the call in `ExUnit.CaptureLog.capture_log/1`
to keep the test output clean, and to assert on the log:

```elixir
log =
  capture_log(fn ->
    assert {:error, %GRPC.RPCError{message: "Internal error"}} = call.()
  end)

assert log =~ "AshGrpc request failed"
```

## Read trailers

Pass `return_headers: true` to get the response trailers:

```elixir
{:ok, reply, %{trailers: trailers}} =
  Stub.create_post(channel, request, metadata: metadata, return_headers: true)
```

## Test deadlines

`timeout:` on a stub call is the client deadline in milliseconds:

```elixir
Stub.slow_posts(channel, %V1.SlowPostsRequest{}, metadata: metadata, timeout: 100)
```

To test the server side without a socket, build a stream with a deadline and
call the generated server through the authenticator interceptor:

```elixir
stream = %GRPC.Server.Stream{
  deadline: System.monotonic_time(:millisecond) + 50,
  http_request_headers: signed_in("alice")
}

assert_raise GRPC.RPCError, ~r/Deadline exceeded/, fn ->
  AshGrpc.Authenticator.Interceptor.call(
    %V1.SlowPostsRequest{},
    stream,
    &MyAppWeb.GrpcEndpoint.Blog.V1.Posts.Server.slow_posts/2,
    MyAppWeb.GrpcAuthenticator
  )
end
```

## Test the `.proto`

`AshGrpc.Proto.render/1` returns `{path, text}` pairs without touching the
disk. A test can compare them with the committed files, which is the
`--check` of `mix ash_grpc.gen.protos`, or run the compatibility comparison:

```elixir
test "the committed proto is current" do
  for {path, text} <- AshGrpc.Proto.render(MyAppWeb.GrpcEndpoint) do
    assert File.read!(Path.join("priv/protos", path)) == text
  end
end

test "the schema did not break clients" do
  [{path, text}] = AshGrpc.Proto.render(MyAppWeb.GrpcEndpoint)
  committed = File.read!(Path.join("priv/protos", path))

  assert AshGrpc.Proto.Compatibility.check(committed, text) == :ok
end
```

## Test that bad blocks stop the build

The library's own tests compile a module from a string and assert on the
error. The same works for your own blocks:

```elixir
assert_raise Spark.Error.DslError, ~r/Field numbers repeat/, fn ->
  Code.compile_string("""
  defmodule BadPost do
    use Ash.Resource, domain: nil, extensions: [AshGrpc.Resource]
    grpc do
      proto_message "BadPost"
      fields id: 1, title: 1
    end
    attributes do
      uuid_primary_key :id, public?: true
      attribute :title, :string, public?: true
    end
  end
  """)
end
```

A bad `rpc` in a domain is raised when an endpoint is compiled, or when
`AshGrpc.Schema.build/1` is called with the domain.
