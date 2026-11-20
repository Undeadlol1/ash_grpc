defmodule AshGrpc.Domain do
  @moduledoc """
  Names the protobuf package and the services and rpcs a domain exposes.

      grpc do
        package "blog.v1"

        service "Posts" do
          resource MyApp.Blog.Post do
            rpc :list_posts, :read
            rpc :update_post
            subscription :watch_posts, :read
          end

          rpc MyApp.Blog.Comment, :add_comment
        end
      end

  Inside `resource` the calls take no resource; the one-line form
  (`rpc MyApp.Blog.Comment, :add_comment`) is the same thing for one call.

  The action defaults to the call's name: `rpc MyApp.Blog.Post, :update_post`
  runs the resource's action `:update_post`. Write it only when they differ,
  as in `:list_posts` above. The name must match exactly.

  The request fields come from the action: for an update or destroy the
  primary key (which looks the record up), then the attributes it accepts,
  then its public arguments, numbered automatically and kept in the committed
  `.proto`. `args` chooses them instead: `[:id, :title]` (exactly these),
  `[id: 1, title: 2]` (pinned numbers), or `[]` (none).

  Each rpc `foo_bar` becomes `FooBar(FooBarRequest) returns (FooBarResponse)`.
  The response holds `result = 1`: the resource message, `repeated` for a read
  that is not `get? true`.

  A read that returns many takes `sort` and `filter` in its request, and
  paging when its action has `pagination`, with nothing written; `sort: false`,
  `filter: false` and `page: false` turn them off. An rpc on an update action
  takes `clear_fields` the same way. See the
  [Paging, sorting and filtering](pagination-sort-filter.md) guide.

  Each subscription `watch_posts` becomes
  `WatchPosts(WatchPostsRequest) returns (stream WatchPostsResponse)`, whose
  response holds `result = 1`, `bool removed = 2`, `bool synced = 3` and `optional uint32 position = 4`. See the
  [Subscriptions](subscriptions.md) guide.

  The block is read by `AshGrpc.Endpoint`, which derives the messages, the
  services and the `.proto` from it. As a verifier it only warns when the
  domain compiles; the endpoint raises for an invalid block, so an invalid
  domain never serves. See the [DSL reference](dsls/DSL-AshGrpc.Domain.md) and
  the [Actions](actions.md) guide.
  """

  use Spark.Dsl.Extension,
    sections: AshGrpc.Domain.Dsl.sections(),
    transformers: [AshGrpc.Domain.Transformers.HoistResourceGroups],
    verifiers: [AshGrpc.Domain.Verifiers.ValidateRpcs]

  alias Mix.Tasks.AshGrpc.Gen.Protos

  @doc """
  Part of `mix ash.codegen`: writes the `.proto` files, or with `--check`
  fails when they are stale. Does nothing until `:endpoints` and
  `:proto_output` are configured for `:ash_grpc`; see `mix ash_grpc.gen.protos`.
  """
  def codegen(argv) do
    if Protos.configured?() do
      flags = Enum.filter(argv, &(&1 in ["--check", "--allow-breaking"]))
      Protos.run(flags)
    else
      Mix.shell().info(
        "Skipping .proto files: configure `:endpoints` and `:proto_output` for :ash_grpc."
      )
    end
  end
end
