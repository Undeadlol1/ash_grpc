defmodule AshGrpc.TestSupport.StreamEntry do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.TestSupport.Streams,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrpc.Resource]

  grpc do
    proto_message "Entry"
    fields id: 1, title: 2, owner: 3
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:title]
      change set_attribute(:owner, actor(:name))
    end

    update :retitle do
      accept [:title]
    end

    action :explode do
      run fn _input, _context -> raise "secret internal detail" end
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(owner == ^actor(:name))
    end

    policy action(:create) do
      forbid_if changing_attributes(title: [to: "classified"])
      authorize_if actor_present()
    end

    policy action(:retitle) do
      authorize_if actor_present()
    end

    policy action(:explode) do
      authorize_if always()
    end
  end

  validations do
    validate string_length(:title, min: 3)
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :owner, :string, public?: true
  end
end

defmodule AshGrpc.TestSupport.Streams do
  @moduledoc false
  use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

  alias AshGrpc.TestSupport.StreamEntry, as: Entry

  grpc do
    package "stream.v1"

    service "Entries" do
      rpc Entry, :post_entries, :create, streaming: :bidirectional, args: [title: 1]

      rpc Entry, :retitle_entries, :retitle,
        streaming: :bidirectional,
        args: [id: 1, title: 2],
        clear_fields: 3

      rpc Entry, :find_entries, :read, streaming: :bidirectional, args: [id: 1]
      rpc Entry, :explode_entries, :explode, streaming: :bidirectional, args: []
      rpc Entry, :import_entries, :create, streaming: :client, args: [title: 1]

      rpc Entry, :import_few_entries, :create,
        streaming: :client,
        max_stream_failures: 2,
        args: [title: 1]

      rpc Entry, :explode_import, :explode, streaming: :client, args: []
      rpc Entry, :list_entries, :read, sort: false, filter: false, page: false
    end
  end

  resources do
    resource Entry
  end
end

defmodule AshGrpc.TestSupport.StreamEndpoint do
  @moduledoc false
  use AshGrpc.Endpoint,
    domains: [AshGrpc.TestSupport.Streams],
    authenticator: AshGrpc.TestSupport.Authenticator,
    reflection: true
end
