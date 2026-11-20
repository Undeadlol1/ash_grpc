defmodule AshGrpc.EndpointTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.GrpcServer
  import ExUnit.CaptureLog

  alias AshGrpc.TestSupport.Endpoint.Blog.V1
  alias AshGrpc.TestSupport.Endpoint.Blog.V1.Posts.Server
  alias AshGrpc.TestSupport.GrpcWebClient
  alias Google.Protobuf.Timestamp
  alias Google.Rpc.BadRequest
  alias GRPC.RPCError
  alias GRPC.Status
  alias V1.Posts.Stub

  setup do
    %{channel: start(), author: "author#{System.unique_integer([:positive])}"}
  end

  defp create(channel, author, request, extra \\ %{}) do
    Stub.create_post(channel, struct(V1.CreatePostRequest, request),
      metadata: signed_in(author, extra)
    )
  end

  defp create!(channel, author, title \\ "A first post") do
    {:ok, %{result: post}} = create(channel, author, title: title)
    post
  end

  test "create sends every type across and returns the stored post", %{
    channel: channel,
    author: author
  } do
    published_at = %Timestamp{seconds: 1_800_000_000, nanos: 123_456_000}

    {:ok, %V1.CreatePostResponse{result: post}} =
      create(channel, author,
        title: "Typed post",
        rating: 4.5,
        published_on: "2026-11-11",
        price: "9.99",
        status: :POST_STATUS_LIVE,
        published_at: published_at
      )

    assert {:ok, _uuid} = Ecto.UUID.cast(post.id)
    assert post.title == "Typed post"
    assert post.body == nil
    assert post.views == 0
    assert post.rating == 4.5
    assert post.published == false
    assert post.published_on == "2026-11-11"
    assert post.price == "9.99"
    assert post.status == :POST_STATUS_LIVE
    assert post.published_at == published_at
    assert %Timestamp{seconds: seconds} = post.inserted_at
    assert_in_delta seconds, System.os_time(:second), 60
    assert post.title_length == 10
  end

  test "an optional field hidden by a field policy is sent unset", %{channel: channel} do
    author = "hush-body"

    assert {:ok, %{result: post}} = create(channel, author, title: "Visible", body: "secret")

    assert post.title == "Visible"
    assert post.body == nil
  end

  test "a required field hidden by a field policy is sent unset and the list still works", %{
    channel: channel
  } do
    hidden = "hush-title"
    create!(channel, hidden, "Secret title")
    create!(channel, "plain-reader", "Open title")

    list = fn name ->
      {:ok, %{result: posts}} =
        Stub.list_posts(channel, %V1.ListPostsRequest{}, metadata: signed_in(name))

      Enum.map(posts, & &1.title)
    end

    assert list.(hidden) == [nil]
    assert list.("plain-reader") == ["Open title"]
  end

  test "a field a field policy can hide is optional in the proto, others are not" do
    [{_path, text}] = AshGrpc.Proto.render(AshGrpc.TestSupport.Endpoint)

    assert text =~ "message Post {\n  string id = 1;\n  optional string title = 2;"
    assert text =~ "message Post {\n  string id = 1;"
  end

  test "a deprecated field and a deprecated rpc with reserved numbers still serve", %{
    channel: channel,
    author: author
  } do
    {:ok, %{result: created}} = create(channel, author, title: "Kept alive")
    assert created.author_name == author

    assert {:ok, %V1.GetPostResponse{result: post}} =
             Stub.get_post(channel, %V1.GetPostRequest{id: created.id},
               metadata: signed_in(author)
             )

    assert post.title == "Kept alive"
    assert post.author_name == author
  end

  test "the actor and tenant from the authenticator reach the action", %{
    channel: channel,
    author: author
  } do
    {:ok, %{result: post}} =
      create(channel, author, [title: "Tenant post"], %{"x-org" => "globex"})

    assert post.author_name == author
    assert post.organization == "globex"

    assert {:ok, %{result: []}} =
             Stub.list_posts(channel, %V1.ListPostsRequest{}, metadata: signed_in(author))

    assert {:ok, %{result: [%{id: id}]}} =
             Stub.list_posts(channel, %V1.ListPostsRequest{},
               metadata: signed_in(author, %{"x-org" => "globex"})
             )

    assert id == post.id
  end

  test "a list read returns the posts the policy lets the actor see", %{
    channel: channel,
    author: author
  } do
    first = create!(channel, author, "First post")
    second = create!(channel, author, "Second post")
    create!(channel, author <> "-other")

    {:ok, %V1.ListPostsResponse{result: posts}} =
      Stub.list_posts(channel, %V1.ListPostsRequest{}, metadata: signed_in(author))

    assert Enum.sort(Enum.map(posts, & &1.id)) == Enum.sort([first.id, second.id])
    assert Enum.sort(Enum.map(posts, & &1.title_length)) == [10, 11]
  end

  test "a get read returns one post", %{channel: channel, author: author} do
    post = create!(channel, author)

    assert {:ok, %V1.GetPostResponse{result: found}} =
             Stub.get_post(channel, %V1.GetPostRequest{id: post.id}, metadata: signed_in(author))

    assert found == post
  end

  test "a get read of a missing post is NOT_FOUND", %{channel: channel, author: author} do
    assert {:error, %RPCError{status: status}} =
             Stub.get_post(channel, %V1.GetPostRequest{id: Ecto.UUID.generate()},
               metadata: signed_in(author)
             )

    assert status == Status.not_found()
  end

  test "an update looks the post up by id and changes only the sent fields", %{
    channel: channel,
    author: author
  } do
    post = create!(channel, author)

    {:ok, %V1.UpdatePostResponse{result: updated}} =
      Stub.update_post(channel, %V1.UpdatePostRequest{id: post.id, body: "New body"},
        metadata: signed_in(author)
      )

    assert updated.id == post.id
    assert updated.title == post.title
    assert updated.body == "New body"
  end

  test "an update finds its record with the rpc's read_action", %{
    channel: channel,
    author: author
  } do
    locked = create!(channel, author, "locked")
    open = create!(channel, author, "open")

    assert {:error, %RPCError{status: status}} =
             Stub.edit_unlocked_post(
               channel,
               %V1.EditUnlockedPostRequest{id: locked.id, body: "x"},
               metadata: signed_in(author)
             )

    assert status == Status.not_found()

    assert {:ok, %V1.EditUnlockedPostResponse{result: updated}} =
             Stub.edit_unlocked_post(
               channel,
               %V1.EditUnlockedPostRequest{id: open.id, body: "x"},
               metadata: signed_in(author)
             )

    assert updated.body == "x"
  end

  test "an update of a missing post is NOT_FOUND", %{channel: channel, author: author} do
    assert {:error, %RPCError{status: status}} =
             Stub.update_post(
               channel,
               %V1.UpdatePostRequest{id: Ecto.UUID.generate(), title: "Nope"},
               metadata: signed_in(author)
             )

    assert status == Status.not_found()
  end

  test "the record lookup of an update is authorized as the actor", %{
    channel: channel,
    author: author
  } do
    post = create!(channel, author)

    assert {:error, %RPCError{status: status}} =
             Stub.update_post(channel, %V1.UpdatePostRequest{id: post.id, title: "Taken over"},
               metadata: signed_in(author <> "-intruder")
             )

    assert status == Status.not_found()
  end

  test "the record lookup of an update uses the tenant", %{channel: channel, author: author} do
    post = create!(channel, author)

    assert {:error, %RPCError{status: status}} =
             Stub.update_post(channel, %V1.UpdatePostRequest{id: post.id, title: "Elsewhere"},
               metadata: signed_in(author, %{"x-org" => "globex"})
             )

    assert status == Status.not_found()
  end

  test "a destroy by id returns the destroyed post", %{channel: channel, author: author} do
    post = create!(channel, author)
    admin = signed_in(author, %{"x-role" => "admin"})

    assert {:ok, %V1.DeletePostResponse{result: %{id: id}}} =
             Stub.delete_post(channel, %V1.DeletePostRequest{id: post.id}, metadata: admin)

    assert id == post.id

    assert {:error, %RPCError{status: status}} =
             Stub.get_post(channel, %V1.GetPostRequest{id: post.id}, metadata: admin)

    assert status == Status.not_found()
  end

  test "a forbidden action is PERMISSION_DENIED", %{channel: channel, author: author} do
    post = create!(channel, author)

    assert {:error, %RPCError{status: status, message: "Forbidden"}} =
             Stub.delete_post(channel, %V1.DeletePostRequest{id: post.id},
               metadata: signed_in(author)
             )

    assert status == Status.permission_denied()
  end

  test "a generic action returns the resource", %{channel: channel, author: author} do
    post = create!(channel, author)

    assert {:ok, %V1.PublishPostResponse{result: published}} =
             Stub.publish_post(channel, %V1.PublishPostRequest{id: post.id},
               metadata: signed_in(author)
             )

    assert published.id == post.id
    assert published.published == true
  end

  test "no credentials is UNAUTHENTICATED", %{channel: channel} do
    assert {:error, %RPCError{status: status}} = Stub.list_posts(channel, %V1.ListPostsRequest{})

    assert status == Status.unauthenticated()
  end

  test "an authenticator that cannot check credentials is UNAVAILABLE", %{channel: channel} do
    assert {:error, %RPCError{status: status}} =
             Stub.list_posts(channel, %V1.ListPostsRequest{}, metadata: signed_in("keys-down"))

    assert status == Status.unavailable()
  end

  defp raw_list_posts(channel, token) do
    headers = %{
      "content-type" => "application/grpc+proto",
      "te" => "trailers",
      "authorization" => "Bearer #{token}"
    }

    response =
      GrpcWebClient.call(
        channel.port,
        "POST",
        "/blog.v1.Posts/ListPosts",
        headers,
        GrpcWebClient.frame(%V1.ListPostsRequest{})
      )

    Map.merge(response.headers, response.trailers)
  end

  test "an authenticator that says when to retry is UNAVAILABLE with the retry pushback trailer",
       %{channel: channel} do
    answer = raw_list_posts(channel, "retry-later")

    assert answer["grpc-status"] == Integer.to_string(Status.unavailable())
    assert answer["grpc-retry-pushback-ms"] == "3000"
  end

  test "an authenticator that only says unavailable sends no retry pushback trailer", %{
    channel: channel
  } do
    answer = raw_list_posts(channel, "keys-down")

    assert answer["grpc-status"] == Integer.to_string(Status.unavailable())
    refute Map.has_key?(answer, "grpc-retry-pushback-ms")
  end

  test "a retry time that is not a non-negative integer is INTERNAL with no pushback trailer", %{
    channel: channel
  } do
    for token <- ["retry-negative", "retry-text"] do
      capture_log(fn ->
        assert {:error, %RPCError{status: status}} =
                 Stub.list_posts(channel, %V1.ListPostsRequest{}, metadata: signed_in(token))

        assert status == Status.internal()
        refute Map.has_key?(raw_list_posts(channel, token), "grpc-retry-pushback-ms")
      end)
    end
  end

  test "a failed validation is INVALID_ARGUMENT naming the field", %{
    channel: channel,
    author: author
  } do
    assert {:error, %RPCError{status: status, details: [detail | _]}} =
             create(channel, author, title: "ab")

    assert status == Status.invalid_argument()
    assert detail.type_url == "type.googleapis.com/google.rpc.BadRequest"

    assert %BadRequest{field_violations: [%{field: "title", description: description}]} =
             BadRequest.decode(detail.value)

    assert description =~ "must have length of at least 3"
  end

  test "a raising action is INTERNAL and sends none of the exception", %{
    channel: channel,
    author: author
  } do
    log =
      capture_log(fn ->
        assert {:error, %RPCError{status: status, message: message}} =
                 Stub.explode(channel, %V1.ExplodeRequest{}, metadata: signed_in(author))

        assert status == Status.internal()
        assert message == "Internal error"
        refute message =~ "hunter2"
      end)

    assert log =~ "hunter2"
  end

  test "a deadline shorter than a slow read is DEADLINE_EXCEEDED", %{
    channel: channel,
    author: author
  } do
    capture_log(fn ->
      assert {:error, %RPCError{status: status}} =
               Stub.slow_posts(channel, %V1.SlowPostsRequest{},
                 metadata: signed_in(author),
                 timeout: 100
               )

      assert status == Status.deadline_exceeded()
    end)
  end

  test "the server cuts a read short at the deadline", %{author: author} do
    assert_raise RPCError, ~r/Deadline exceeded/, fn ->
      authenticated(&Server.slow_posts/2, %V1.SlowPostsRequest{}, author, 50)
    end
  end

  test "the server cuts a generic action short at the deadline", %{author: author} do
    error =
      assert_raise RPCError, fn ->
        authenticated(&Server.nap/2, %V1.NapRequest{}, author, 50)
      end

    assert error.status == Status.deadline_exceeded()
  end

  test "a generic action within the deadline answers", %{author: author} do
    assert %V1.NapResponse{result: %{title: "awake"}} =
             authenticated(&Server.nap/2, %V1.NapRequest{}, author, 5_000)
  end

  test "a slow record lookup of an update is cut at the deadline", %{channel: channel} do
    author = "sleepy-lookup"
    post = create!(channel, author)

    {elapsed_ms, error} =
      timed(fn ->
        assert_raise RPCError, fn ->
          authenticated(&Server.update_post/2, %V1.UpdatePostRequest{id: post.id}, author, 100)
        end
      end)

    assert error.status == Status.deadline_exceeded()
    assert elapsed_ms < 600
  end

  test "a slow record lookup of a destroy is cut at the deadline", %{channel: channel} do
    author = "sleepy-lookup"
    post = create!(channel, author)

    {elapsed_ms, error} =
      timed(fn ->
        assert_raise RPCError, fn ->
          authenticated(&Server.delete_post/2, %V1.DeletePostRequest{id: post.id}, author, 100, %{
            "x-role" => "admin"
          })
        end
      end)

    assert error.status == Status.deadline_exceeded()
    assert elapsed_ms < 600
  end

  test "a slow load of the result is cut at the deadline", %{channel: channel} do
    author = "sleepy-load"
    post = create!(channel, author)

    {elapsed_ms, error} =
      timed(fn ->
        assert_raise RPCError, fn ->
          authenticated(&Server.update_post/2, %V1.UpdatePostRequest{id: post.id}, author, 100)
        end
      end)

    assert error.status == Status.deadline_exceeded()
    assert elapsed_ms < 600
  end

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - started, result}
  end

  defp authenticated(rpc, request, author, deadline_ms, extra \\ %{}) do
    stream = %GRPC.Server.Stream{
      deadline: System.monotonic_time(:millisecond) + deadline_ms,
      http_request_headers: signed_in(author, extra)
    }

    AshGrpc.Authenticator.Interceptor.call(
      request,
      stream,
      rpc,
      AshGrpc.TestSupport.Authenticator
    )
  end
end
