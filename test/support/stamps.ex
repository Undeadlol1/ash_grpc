defmodule AshGrpc.TestSupport.Stamps.Event do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.TestSupport.Stamps,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshGrpc.Resource]

  grpc do
    proto_message "Event"
    fields at: 1, label: 2
  end

  actions do
    defaults [:read, :destroy, create: [:at, :label], update: [:label]]
  end

  attributes do
    attribute :at, :utc_datetime, primary_key?: true, allow_nil?: false, public?: true
    attribute :label, :string, public?: true
  end
end

defmodule AshGrpc.TestSupport.Stamps.Level do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.TestSupport.Stamps,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshGrpc.Resource]

  grpc do
    proto_message "Level"
    fields rank: 1, label: 2
  end

  actions do
    defaults [:read, :destroy, create: [:rank, :label], update: [:label]]
  end

  attributes do
    attribute :rank, :atom,
      primary_key?: true,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:low, :high]]

    attribute :label, :string, public?: true
  end
end

defmodule AshGrpc.TestSupport.Stamps do
  @moduledoc false
  use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

  alias AshGrpc.TestSupport.Stamps.Event
  alias AshGrpc.TestSupport.Stamps.Level

  grpc do
    package "stamps.v1"

    service "Stamps" do
      rpc Event, :get_event, :read, args: [at: 1], sort: false, filter: false, page: false

      rpc Event, :update_event, :update,
        clear_fields: false,
        args: [at: 1, label: 2],
        sort: false,
        filter: false,
        page: false

      rpc Event, :delete_events, :destroy, bulk?: true, args: [at: 1]

      rpc Level, :get_level, :read, args: [rank: 1], sort: false, filter: false, page: false

      rpc Level, :update_level, :update,
        clear_fields: false,
        args: [rank: 1, label: 2],
        sort: false,
        filter: false,
        page: false
    end
  end

  resources do
    resource Event
    resource Level
  end
end

defmodule AshGrpc.TestSupport.StampsEndpoint do
  @moduledoc false
  use AshGrpc.Endpoint,
    domains: [AshGrpc.TestSupport.Stamps],
    authenticator: AshGrpc.TestSupport.Authenticator
end
