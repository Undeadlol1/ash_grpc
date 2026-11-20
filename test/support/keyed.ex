defmodule AshGrpc.TestSupport.Counter do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.TestSupport.Keys,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshGrpc.Resource]

  grpc do
    proto_message "Counter"
    fields id: 1, label: 2
  end

  actions do
    defaults [:read, :destroy, create: [:label], update: [:label]]
  end

  attributes do
    integer_primary_key :id, public?: true
    attribute :label, :string, public?: true
  end
end

defmodule AshGrpc.TestSupport.Tag do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.TestSupport.Keys,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshGrpc.Resource]

  grpc do
    proto_message "Tag"
    fields code: 1, label: 2
  end

  actions do
    defaults [:read, :destroy, create: [:code, :label], update: [:label]]
  end

  attributes do
    attribute :code, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :label, :string, public?: true
  end
end

defmodule AshGrpc.TestSupport.Keys do
  @moduledoc false
  use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

  alias AshGrpc.TestSupport.Counter
  alias AshGrpc.TestSupport.Tag

  grpc do
    package "keys.v1"

    service "Keys" do
      rpc Counter, :get_counter, :read,
        args: [id: 1],
        sort: false,
        filter: false,
        page: false

      rpc Tag, :get_tag, :read,
        args: [code: 1],
        sort: false,
        filter: false,
        page: false

      rpc Counter, :update_counter, :update,
        clear_fields: false,
        args: [id: 1, label: 2],
        sort: false,
        filter: false,
        page: false

      rpc Counter, :delete_counter, :destroy,
        args: [id: 1],
        sort: false,
        filter: false,
        page: false

      rpc Tag, :update_tag, :update,
        clear_fields: false,
        args: [code: 1, label: 2],
        sort: false,
        filter: false,
        page: false

      rpc Tag, :delete_tag, :destroy,
        args: [code: 1],
        sort: false,
        filter: false,
        page: false
    end
  end

  resources do
    resource Counter
    resource Tag
  end
end

defmodule AshGrpc.TestSupport.KeysEndpoint do
  @moduledoc false
  use AshGrpc.Endpoint,
    domains: [AshGrpc.TestSupport.Keys],
    authenticator: AshGrpc.TestSupport.Authenticator
end
