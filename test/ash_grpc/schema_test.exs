defmodule AshGrpc.SchemaTest do
  use ExUnit.Case, async: true

  alias AshGrpc.TestSupport.Endpoint.Blog.V1
  alias AshGrpc.TestSupport.Endpoint.Blog.V1.Posts.Service
  alias Google.Protobuf.Timestamp

  defp fields(module) do
    module.__message_props__().field_props
    |> Map.values()
    |> Enum.sort_by(& &1.fnum)
    |> Enum.map(&{&1.name_atom, &1.fnum, &1.type, &1.repeated?, &1.proto3_optional?})
  end

  test "the resource message has every exposed field with its number, type and presence" do
    timestamp = Timestamp

    assert V1.Post.full_name() == "blog.v1.Post"

    assert fields(V1.Post) == [
             {:id, 1, :string, false, false},
             {:title, 2, :string, false, true},
             {:body, 3, :string, false, true},
             {:views, 4, :int64, false, true},
             {:rating, 5, :double, false, true},
             {:published, 6, :bool, false, true},
             {:published_on, 7, :string, false, true},
             {:price, 8, :string, false, true},
             {:status, 9, {:enum, V1.PostStatus}, false, true},
             {:inserted_at, 10, timestamp, false, false},
             {:published_at, 11, timestamp, false, false},
             {:title_length, 12, :int64, false, true},
             {:organization, 13, :string, false, true},
             {:author_name, 14, :string, false, true},
             {:slow_mark, 17, :string, false, true}
           ]
  end

  test "a deprecated field carries the flag in its protobuf module" do
    props = V1.Post.__message_props__().field_props

    assert props[14].deprecated?
    refute props[2].deprecated?
  end

  test "a request without args has no fields" do
    assert fields(V1.ListPostsRequest) == []
    assert fields(V1.ExplodeRequest) == []
  end

  test "every scalar request field is optional so an omitted one is told from an empty one" do
    assert fields(V1.GetPostRequest) == [{:id, 1, :string, false, true}]

    assert fields(V1.CreatePostRequest) == [
             {:title, 1, :string, false, true},
             {:body, 2, :string, false, true},
             {:rating, 3, :double, false, true},
             {:published_on, 4, :string, false, true},
             {:price, 5, :string, false, true},
             {:status, 6, {:enum, V1.PostStatus}, false, true},
             {:published_at, 7, Timestamp, false, false}
           ]
  end

  test "an update takes its primary key and attributes as optional wire fields" do
    assert fields(V1.UpdatePostRequest) == [
             {:id, 1, :string, false, true},
             {:title, 2, :string, false, true},
             {:body, 3, :string, false, true},
             {:clear_fields, 4, :string, true, false}
           ]

    assert fields(V1.DeletePostRequest) == [{:id, 1, :string, false, true}]
  end

  test "a list read answers a repeated result and every other rpc a single one" do
    assert fields(V1.ListPostsResponse) == [{:result, 1, V1.Post, true, false}]
    assert fields(V1.GetPostResponse) == [{:result, 1, V1.Post, false, false}]
    assert fields(V1.CreatePostResponse) == [{:result, 1, V1.Post, false, false}]
    assert fields(V1.PublishPostResponse) == [{:result, 1, V1.Post, false, false}]
  end

  test "the service names every rpc in camel case" do
    names = Enum.map(Service.__rpc_calls__(), &elem(&1, 0))

    assert names == [
             :ListPosts,
             :GetPost,
             :FindPost,
             :CreatePost,
             :UpdatePost,
             :EditUnlockedPost,
             :DeletePost,
             :PublishPost,
             :Explode,
             :SlowPosts,
             :PagedPosts,
             :RetitlePost,
             :Preloaded,
             :Vanish,
             :Nap
           ]

    assert Service.__meta__(:name) == "blog.v1.Posts"
  end
end
