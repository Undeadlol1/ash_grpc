defmodule AshGrpc.TestSupport.Library.Author do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.TestSupport.Library,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshGrpc.Resource]

  grpc do
    proto_message "Author"
    fields id: 1, name: 2, name_length: 3, book_count: 4, books: 5, profile: 6
  end

  actions do
    defaults [:read, :destroy, create: [:name], update: [:name]]

    create :create_with_books do
      accept [:name]
      argument :books, {:array, :map}
      change manage_relationship(:books, type: :create)
    end
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :name, :string, public?: true
  end

  relationships do
    has_many :books, AshGrpc.TestSupport.Library.Book, public?: true
    has_one :profile, AshGrpc.TestSupport.Library.Profile, public?: true
  end

  calculations do
    calculate :name_length, :integer, expr(string_length(name)), public?: true
  end

  aggregates do
    count :book_count, :books, public?: true
  end
end

defmodule AshGrpc.TestSupport.Library.Profile do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.TestSupport.Library,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrpc.Resource]

  grpc do
    proto_message "Profile"
    fields id: 1, bio: 2, author: 3
  end

  actions do
    defaults [:read, create: [:bio, :author_id]]
  end

  policies do
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy always() do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :bio, :string, public?: true
  end

  relationships do
    belongs_to :author, AshGrpc.TestSupport.Library.Author, public?: true
  end
end

defmodule AshGrpc.TestSupport.Library.BookTag do
  @moduledoc false
  use Ash.Resource, domain: AshGrpc.TestSupport.Library, data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy, create: [:book_id, :tag_id]]
  end

  relationships do
    belongs_to :book, AshGrpc.TestSupport.Library.Book, primary_key?: true, allow_nil?: false
    belongs_to :tag, AshGrpc.TestSupport.Library.Tag, primary_key?: true, allow_nil?: false
  end
end

defmodule AshGrpc.TestSupport.Library.Tag do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.TestSupport.Library,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshGrpc.Resource]

  grpc do
    proto_message "Tag"
    fields id: 1, label: 2, books: 3
  end

  actions do
    defaults [:read, create: [:label]]
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :label, :string, public?: true
  end

  relationships do
    many_to_many :books, AshGrpc.TestSupport.Library.Book,
      through: AshGrpc.TestSupport.Library.BookTag,
      source_attribute_on_join_resource: :tag_id,
      destination_attribute_on_join_resource: :book_id,
      public?: true
  end
end

defmodule AshGrpc.TestSupport.Library.Book do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.TestSupport.Library,
    data_layer: Ash.DataLayer.Ets,
    simple_notifiers: [AshGrpc.Notifier],
    extensions: [AshGrpc.Resource]

  grpc do
    proto_message "Book"
    fields id: 1, title: 2, author: 3, tags: 4
  end

  actions do
    defaults [:read, :destroy, create: [:title, :author_id], update: [:title]]

    action :favourite, :struct do
      constraints instance_of: __MODULE__
      run fn _input, context -> Ash.read_first(__MODULE__, Ash.Context.to_opts(context)) end
    end
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :title, :string, public?: true
  end

  relationships do
    belongs_to :author, AshGrpc.TestSupport.Library.Author, public?: true

    many_to_many :tags, AshGrpc.TestSupport.Library.Tag,
      through: AshGrpc.TestSupport.Library.BookTag,
      source_attribute_on_join_resource: :book_id,
      destination_attribute_on_join_resource: :tag_id,
      public?: true
  end
end

defmodule AshGrpc.TestSupport.Library do
  @moduledoc false
  use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

  alias AshGrpc.TestSupport.Library.Author
  alias AshGrpc.TestSupport.Library.Book

  grpc do
    package "library.v1"

    service "Library" do
      rpc Author, :list_authors, :read,
        sort: false,
        filter: false,
        page: false

      rpc Author, :list_authors_with_books, :read,
        load: [:books],
        sort: false,
        filter: false,
        page: false

      rpc Author, :list_authors_with_profile, :read,
        load: [:profile],
        sort: false,
        filter: false,
        page: false

      rpc Author, :list_authors_deep, :read,
        sort: false,
        filter: false,
        page: false,
        load: [books: [:tags, :author], profile: :author]

      rpc Author, :create_author, :create,
        sort: false,
        filter: false,
        page: false,
        args: [name: 1],
        load: [:books]

      rpc Author, :create_author_with_books, :create_with_books,
        sort: false,
        filter: false,
        page: false,
        args: [name: 1, books: 2],
        load: [:books]

      rpc Book, :list_books, :read,
        load: [:author, :tags],
        sort: false,
        filter: false,
        page: false

      rpc Book, :get_book, :read,
        args: [id: 1],
        load: [:author],
        sort: false,
        filter: false,
        page: false

      rpc Book, :update_book, :update,
        clear_fields: false,
        sort: false,
        filter: false,
        page: false,
        args: [id: 1, title: 2],
        load: [:author]

      rpc Book, :destroy_book, :destroy,
        sort: false,
        filter: false,
        page: false,
        args: [id: 1],
        load: [:author]

      rpc Book, :favourite_book, :favourite,
        load: [:author],
        sort: false,
        filter: false,
        page: false

      subscription Book, :watch_books, :read,
        load: [:author],
        sort: false,
        filter: false
    end
  end

  resources do
    resource Author
    resource AshGrpc.TestSupport.Library.Profile
    resource AshGrpc.TestSupport.Library.Tag
    resource Book
    resource AshGrpc.TestSupport.Library.BookTag
  end
end

defmodule AshGrpc.TestSupport.LibraryEndpoint do
  @moduledoc false
  use AshGrpc.Endpoint,
    domains: [AshGrpc.TestSupport.Library],
    authenticator: AshGrpc.TestSupport.Authenticator
end
