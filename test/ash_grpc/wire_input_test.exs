defmodule AshGrpc.WireInputTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.GrpcServer

  alias AshGrpc.TestSupport.Endpoint.Blog.V1
  alias AshGrpc.TestSupport.KeysEndpoint.Keys.V1, as: Keys
  alias AshGrpc.TestSupport.KeysEndpoint.Keys.V1.Keys.Stub, as: KeysStub
  alias Google.Protobuf.Timestamp
  alias Google.Rpc.BadRequest
  alias GRPC.RPCError
  alias GRPC.Status
  alias V1.Posts.Stub

  setup do
    %{channel: start(), author: "author#{System.unique_integer([:positive])}"}
  end

  defp create(channel, author, request) do
    Stub.create_post(channel, struct(V1.CreatePostRequest, request), metadata: signed_in(author))
  end

  defp violated_fields({:error, %RPCError{status: status, details: details}}) do
    assert status == Status.invalid_argument()

    for %{type_url: "type.googleapis.com/google.rpc.BadRequest"} = detail <- details,
        violation <- BadRequest.decode(detail.value).field_violations,
        do: violation.field
  end

  test "violation descriptions carry no bread crumbs or internal module names", %{
    channel: channel,
    author: author
  } do
    {:error, %RPCError{details: details}} = create(channel, author, body: "no title")

    descriptions =
      for %{type_url: "type.googleapis.com/google.rpc.BadRequest"} = detail <- details,
          violation <- BadRequest.decode(detail.value).field_violations,
          do: violation.description

    assert descriptions != []

    for description <- descriptions,
        leak <- ["Bread Crumbs", "Error returned from", "AshGrpc"] do
      refute description =~ leak
    end
  end

  test "an omitted required argument is INVALID_ARGUMENT naming the field", %{
    channel: channel,
    author: author
  } do
    assert violated_fields(create(channel, author, body: "no title")) == ["title"]
  end

  test "an omitted primary key is INVALID_ARGUMENT naming the field", %{
    channel: channel,
    author: author
  } do
    result =
      Stub.update_post(channel, %V1.UpdatePostRequest{title: "Lost"}, metadata: signed_in(author))

    assert violated_fields(result) == ["id"]
  end

  test "a timestamp outside the date range is INVALID_ARGUMENT naming the field", %{
    channel: channel,
    author: author
  } do
    published_at = %Timestamp{seconds: 999_999_999_999_999, nanos: 0}

    assert violated_fields(create(channel, author, title: "Far away", published_at: published_at)) ==
             ["published_at"]
  end

  test "a timestamp with nanos outside its range is INVALID_ARGUMENT naming the field", %{
    channel: channel,
    author: author
  } do
    published_at = %Timestamp{seconds: 1_800_000_000, nanos: 2_000_000_000}

    assert violated_fields(
             create(channel, author, title: "Bad nanos", published_at: published_at)
           ) ==
             ["published_at"]
  end

  test "a malformed decimal is INVALID_ARGUMENT naming the field", %{
    channel: channel,
    author: author
  } do
    assert violated_fields(create(channel, author, title: "Priced", price: "twelve")) == ["price"]
  end

  test "a malformed date is INVALID_ARGUMENT naming the field", %{
    channel: channel,
    author: author
  } do
    assert violated_fields(create(channel, author, title: "Dated", published_on: "someday")) ==
             ["published_on"]
  end

  test "an enum number outside the known values is INVALID_ARGUMENT naming the field", %{
    channel: channel,
    author: author
  } do
    assert violated_fields(create(channel, author, title: "Status", status: 99)) == [
             "status"
           ]
  end

  test "a malformed uuid argument is INVALID_ARGUMENT naming the field", %{
    channel: channel,
    author: author
  } do
    result =
      Stub.get_post(channel, %V1.GetPostRequest{id: "not-a-uuid"}, metadata: signed_in(author))

    assert violated_fields(result) == ["id"]
  end

  defp update(channel, author, request) do
    Stub.update_post(channel, struct(V1.UpdatePostRequest, request), metadata: signed_in(author))
  end

  defp post_with_body(channel, author) do
    {:ok, %{result: post}} = create(channel, author, title: "Has a body", body: "Some body")
    post
  end

  test "a field named in clear_fields is set to nil", %{channel: channel, author: author} do
    post = post_with_body(channel, author)

    {:ok, %{result: updated}} = update(channel, author, id: post.id, clear_fields: ["body"])

    assert updated.body == nil
    assert updated.title == post.title
  end

  test "an update that names nothing in clear_fields leaves omitted fields alone", %{
    channel: channel,
    author: author
  } do
    post = post_with_body(channel, author)

    {:ok, %{result: updated}} = update(channel, author, id: post.id, title: "Renamed")

    assert updated.body == "Some body"
  end

  test "clearing an attribute that does not allow nil is INVALID_ARGUMENT naming it", %{
    channel: channel,
    author: author
  } do
    post = post_with_body(channel, author)

    assert violated_fields(update(channel, author, id: post.id, clear_fields: ["title"])) ==
             ["title"]
  end

  test "an unknown name in clear_fields is INVALID_ARGUMENT naming clear_fields", %{
    channel: channel,
    author: author
  } do
    post = post_with_body(channel, author)

    assert violated_fields(update(channel, author, id: post.id, clear_fields: ["views"])) ==
             ["clear_fields"]
  end

  test "the primary key in clear_fields is INVALID_ARGUMENT naming clear_fields", %{
    channel: channel,
    author: author
  } do
    post = post_with_body(channel, author)

    assert violated_fields(update(channel, author, id: post.id, clear_fields: ["id"])) ==
             ["clear_fields"]
  end

  test "a field both sent and named in clear_fields is INVALID_ARGUMENT naming clear_fields", %{
    channel: channel,
    author: author
  } do
    post = post_with_body(channel, author)

    result = update(channel, author, id: post.id, body: "Kept?", clear_fields: ["body"])

    assert violated_fields(result) == ["clear_fields"]
  end

  test "a malformed uuid primary key is INVALID_ARGUMENT", %{channel: channel, author: author} do
    result =
      Stub.update_post(channel, %V1.UpdatePostRequest{id: "not-a-uuid", title: "Nope"},
        metadata: signed_in(author)
      )

    assert violated_fields(result) == ["id"]
  end

  test "an empty uuid primary key is INVALID_ARGUMENT naming the field", %{
    channel: channel,
    author: author
  } do
    result =
      Stub.update_post(channel, %V1.UpdatePostRequest{id: "", title: "Nope"},
        metadata: signed_in(author)
      )

    assert violated_fields(result) == ["id"]
  end

  test "an empty string primary key is INVALID_ARGUMENT naming the field", %{author: author} do
    channel = start(AshGrpc.TestSupport.KeysEndpoint)

    result =
      KeysStub.update_tag(channel, %Keys.UpdateTagRequest{code: "", label: "Nope"},
        metadata: signed_in(author)
      )

    assert violated_fields(result) == ["code"]
  end

  test "an empty integer primary key is INVALID_ARGUMENT naming the field", %{author: author} do
    stream = %GRPC.Server.Stream{http_request_headers: signed_in(author)}
    call = &Keys.Keys.Server.update_counter(%{id: "", label: "Nope"}, &1)

    error = assert_raise RPCError, fn -> through_authenticator(call, stream) end

    assert error.status == Status.invalid_argument()

    assert [%{field: "id"}] =
             BadRequest.decode(hd(error.details).value).field_violations
  end

  defp through_authenticator(call, stream) do
    AshGrpc.Authenticator.Interceptor.call(
      nil,
      stream,
      fn _request, stream -> call.(stream) end,
      AshGrpc.TestSupport.Authenticator
    )
  end

  test "a single-result action that returns nothing is NOT_FOUND", %{
    channel: channel,
    author: author
  } do
    assert {:error, %RPCError{status: status}} =
             Stub.vanish(channel, %V1.VanishRequest{}, metadata: signed_in(author))

    assert status == Status.not_found()
  end

  test "a calculation the action already set is not recomputed", %{
    channel: channel,
    author: author
  } do
    assert {:ok, %V1.PreloadedResponse{result: post}} =
             Stub.preloaded(channel, %V1.PreloadedRequest{}, metadata: signed_in(author))

    assert post.title_length == 99
  end

  test "an optionally paginated read answers every record as a list", %{
    channel: channel,
    author: author
  } do
    for title <- ["First post", "Second post"], do: create(channel, author, title: title)

    assert {:ok, %V1.PagedPostsResponse{result: posts}} =
             Stub.paged_posts(channel, %V1.PagedPostsRequest{}, metadata: signed_in(author))

    assert length(posts) == 2
  end

  test "a primary key that is also an action argument still looks the record up", %{
    channel: channel,
    author: author
  } do
    {:ok, %{result: first}} = create(channel, author, title: "First post")
    {:ok, %{result: other}} = create(channel, author, title: "Other post")

    assert {:ok, %V1.RetitlePostResponse{result: retitled}} =
             Stub.retitle_post(channel, %V1.RetitlePostRequest{id: first.id, title: "Renamed"},
               metadata: signed_in(author)
             )

    assert retitled.id == first.id
    assert retitled.title == "Renamed"

    assert {:ok, %{result: untouched}} =
             Stub.get_post(channel, %V1.GetPostRequest{id: other.id}, metadata: signed_in(author))

    assert untouched.title == "Other post"
  end

  test "a destroy replies with the calculations of the record it deleted", %{
    channel: channel,
    author: author
  } do
    {:ok, %{result: post}} = create(channel, author, title: "Doomed post")
    admin = signed_in(author, %{"x-role" => "admin"})

    assert {:ok, %V1.DeletePostResponse{result: deleted}} =
             Stub.delete_post(channel, %V1.DeletePostRequest{id: post.id}, metadata: admin)

    assert deleted.title_length == 11
  end
end
