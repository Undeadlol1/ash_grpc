defmodule AshGrpc.TestSupport.Dispatch do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.TestSupport.Grouped,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshGrpc.Resource]

  grpc do
    proto_message "Dispatch"
    fields id: 1, title: 2
  end

  actions do
    create :create_dispatch do
      accept [:title]
    end

    read :list_dispatches do
      primary? true
    end
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :title, :string, public?: true
  end
end

defmodule AshGrpc.TestSupport.Grouped do
  @moduledoc false
  use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

  alias AshGrpc.TestSupport.Dispatch

  grpc do
    package "grouped.v1"

    service "Dispatches" do
      resource Dispatch do
        rpc(:create_dispatch)
        rpc(:list_dispatches, sort: false, filter: false, page: false)
      end
    end
  end

  resources do
    resource Dispatch
  end
end

Application.put_env(
  :ash_grpc,
  :proto_output,
  Path.join(System.tmp_dir!(), "ash_grpc_grouped_#{System.unique_integer([:positive])}")
)

defmodule AshGrpc.TestSupport.GroupedEndpoint do
  @moduledoc false
  use AshGrpc.Endpoint,
    domains: [AshGrpc.TestSupport.Grouped],
    authenticator: AshGrpc.TestSupport.Authenticator
end

Application.delete_env(:ash_grpc, :proto_output)
