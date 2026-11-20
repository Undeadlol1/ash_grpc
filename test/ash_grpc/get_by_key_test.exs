defmodule AshGrpc.GetByKeyTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.Compile
  import AshGrpc.TestSupport.GrpcServer

  alias AshGrpc.TestSupport.Counter
  alias AshGrpc.TestSupport.Endpoint.Blog.V1, as: Blog
  alias AshGrpc.TestSupport.Endpoint.Blog.V1.Posts.Stub
  alias AshGrpc.TestSupport.KeysEndpoint.Keys.V1, as: Keys
  alias AshGrpc.TestSupport.KeysEndpoint.Keys.V1.Keys.Stub, as: KeysStub
  alias GRPC.RPCError
  alias GRPC.Status
  alias Spark.Error.DslError

  setup do
    %{author: "author#{System.unique_integer([:positive])}"}
  end

  describe "a plain read that lists the whole primary key" do
    setup do
      channel = start(AshGrpc.TestSupport.KeysEndpoint)

      counter =
        Ash.Seed.seed!(Counter, %{
          id: System.unique_integer([:positive]),
          label: "wanted"
        })

      Ash.Seed.seed!(Counter, %{
        id: System.unique_integer([:positive]),
        label: "other"
      })

      %{channel: channel, counter: counter}
    end

    test "answers one record as a single message", ctx do
      assert {:ok, %Keys.GetCounterResponse{result: %Keys.Counter{id: id, label: "wanted"}}} =
               KeysStub.get_counter(ctx.channel, %Keys.GetCounterRequest{id: ctx.counter.id},
                 metadata: signed_in(ctx.author)
               )

      assert id == ctx.counter.id
    end

    test "a missing record is NOT_FOUND", ctx do
      assert {:error, %RPCError{status: status}} =
               KeysStub.get_counter(ctx.channel, %Keys.GetCounterRequest{id: 987_654},
                 metadata: signed_in(ctx.author)
               )

      assert status == Status.not_found()
    end

    test "a string key works too", ctx do
      code = "k#{System.unique_integer([:positive])}"
      Ash.Seed.seed!(AshGrpc.TestSupport.Tag, %{code: code, label: "tagged"})

      assert {:ok, %Keys.GetTagResponse{result: %Keys.Tag{label: "tagged"}}} =
               KeysStub.get_tag(ctx.channel, %Keys.GetTagRequest{code: code},
                 metadata: signed_in(ctx.author)
               )
    end

    test "an omitted key is INVALID_ARGUMENT", ctx do
      assert {:error, %RPCError{status: status}} =
               KeysStub.get_counter(ctx.channel, %Keys.GetCounterRequest{},
                 metadata: signed_in(ctx.author)
               )

      assert status == Status.invalid_argument()
    end
  end

  describe "policies" do
    setup do
      %{channel: start()}
    end

    test "apply as for any read", %{channel: channel, author: author} do
      {:ok, %{result: post}} =
        Stub.create_post(channel, %Blog.CreatePostRequest{title: "Mine"},
          metadata: signed_in(author)
        )

      assert {:ok, %Blog.FindPostResponse{result: %Blog.Post{title: "Mine"}}} =
               Stub.find_post(channel, %Blog.FindPostRequest{id: post.id},
                 metadata: signed_in(author)
               )

      assert {:error, %RPCError{status: status}} =
               Stub.find_post(channel, %Blog.FindPostRequest{id: post.id},
                 metadata: signed_in(author <> "-intruder")
               )

      assert status == Status.not_found()
    end
  end

  describe "the build" do
    @composite """
    grpc do
      proto_message "Pair"
      fields a: 1, b: 2, label: 3
    end

    attributes do
      attribute :a, :integer, primary_key?: true, allow_nil?: false, public?: true
      attribute :b, :integer, primary_key?: true, allow_nil?: false, public?: true
      attribute :label, :string, public?: true
    end

    actions do
      defaults [:read]
    end
    """

    test "stops when a read lists only part of a composite key" do
      domain =
        compile_domain(
          ~s(package "pairs.v1"\nservice "Pairs" do\n rpc INLINE, :get_pair, :read, args: [a: 1]\n end),
          @composite
        )

      assert_raise DslError, ~r/rpc :get_pair.*only part of the primary key \[:a, :b\]/s, fn ->
        AshGrpc.Schema.build([domain])
      end
    end

    test "accepts a read that lists the whole composite key" do
      domain =
        compile_domain(
          ~s(package "pairs.v1"\nservice "Pairs" do\n rpc INLINE, :get_pair, :read, args: [a: 1, b: 2]\n end),
          @composite
        )

      assert [%{services: [%{rpcs: [%{many?: false}]}]}] = AshGrpc.Schema.build([domain])
    end
  end
end
