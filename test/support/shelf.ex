defmodule AshGrpc.TestSupport.Book do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.TestSupport.Shelf,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    simple_notifiers: [AshGrpc.Notifier],
    extensions: [AshGrpc.Resource]

  grpc do
    proto_message "Book"
    fields id: 1, title: 2, pages: 3, genre: 4, owner: 5
  end

  actions do
    defaults [
      :read,
      :destroy,
      create: [:title, :pages, :genre, :owner, :secret],
      update: [:title, :genre]
    ]

    read :paged do
      pagination offset?: true,
                 keyset?: true,
                 countable: true,
                 required?: false,
                 default_limit: 2,
                 max_page_size: 3
    end

    read :keyset_only do
      pagination keyset?: true, required?: false
    end

    read :required do
      pagination offset?: true, required?: true
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(owner == ^actor(:name))
    end

    policy always() do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :pages, :integer, public?: true
    attribute :genre, :string, public?: true
    attribute :owner, :string, allow_nil?: false, public?: true
    attribute :secret, :string
  end
end

defmodule AshGrpc.TestSupport.Shelf do
  @moduledoc false
  use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

  alias AshGrpc.TestSupport.Book

  grpc do
    package "shelf.v1"

    service "Shelf" do
      rpc Book, :list_books, :read, sort: false, filter: false, page: false
      rpc Book, :search_books, :read, sort: 1, filter: 2, page: false

      rpc Book, :page_books, :paged,
        page: [limit: 1, offset: 2, after: 3, before: 4, count: 5],
        sort: 6,
        filter: 7

      rpc Book, :scroll_books, :keyset_only,
        page: [limit: 1, after: 2, before: 3],
        sort: false,
        filter: false

      rpc Book, :required_books, :required,
        page: [limit: 1, offset: 2],
        sort: false,
        filter: false

      subscription Book, :watch_books, :read, sort: 1, filter: 2
    end
  end

  resources do
    resource Book
  end
end

defmodule AshGrpc.TestSupport.ShelfEndpoint do
  @moduledoc false
  use AshGrpc.Endpoint,
    domains: [AshGrpc.TestSupport.Shelf],
    authenticator: AshGrpc.TestSupport.Authenticator
end
