defmodule AshGrpc.TestSupport.Blog do
  @moduledoc false
  use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

  alias AshGrpc.TestSupport.Post

  grpc do
    package "blog.v1"

    service "Posts" do
      rpc Post, :list_posts, :read, sort: false, filter: false, page: false

      rpc Post, :get_post, :by_id,
        args: [id: 1],
        reserved: [2, 3],
        sort: false,
        filter: false,
        page: false

      rpc Post, :find_post, :read, args: [id: 1], sort: false, filter: false, page: false

      rpc Post, :create_post, :create,
        sort: false,
        filter: false,
        page: false,
        args: [
          title: 1,
          body: 2,
          rating: 3,
          published_on: 4,
          price: 5,
          status: 6,
          published_at: 7
        ]

      rpc Post, :update_post, :update,
        sort: false,
        filter: false,
        page: false,
        args: [id: 1, title: 2, body: 3],
        clear_fields: 4

      rpc Post, :edit_unlocked_post, :update,
        clear_fields: false,
        sort: false,
        filter: false,
        page: false,
        args: [id: 1, body: 2],
        read_action: :unlocked

      rpc Post, :delete_post, :destroy, args: [id: 1], sort: false, filter: false, page: false
      rpc Post, :publish_post, :publish, args: [id: 1], sort: false, filter: false, page: false
      rpc Post, :explode, :explode, sort: false, filter: false, page: false
      rpc Post, :slow_posts, :slow, sort: false, filter: false, page: false
      rpc Post, :paged_posts, :paged, sort: false, filter: false, page: false

      rpc Post, :retitle_post, :retitle,
        clear_fields: false,
        args: [id: 1, title: 2],
        sort: false,
        filter: false,
        page: false

      rpc Post, :preloaded, :preloaded, sort: false, filter: false, page: false
      rpc Post, :vanish, :vanish, sort: false, filter: false, page: false
      rpc Post, :nap, :nap, deprecated: true, sort: false, filter: false, page: false
    end
  end

  resources do
    resource Post
  end
end
