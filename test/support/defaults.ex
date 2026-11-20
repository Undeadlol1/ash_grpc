defmodule AshGrpc.TestSupport.Logbook do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.TestSupport.Defaults,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshGrpc.Resource]

  grpc do
    proto_message "Logbook"
    fields id: 1, title: 2
  end

  actions do
    create :create_logbook do
      accept [:title]
    end

    read :list_logbooks do
      primary? true
    end
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :title, :string, public?: true
  end
end

defmodule AshGrpc.TestSupport.Defaults do
  @moduledoc false
  use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

  alias AshGrpc.TestSupport.Logbook

  grpc do
    package "defaults.v1"

    service "Logbooks" do
      rpc(Logbook, :create_logbook)
      rpc Logbook, :list_logbooks, sort: false, filter: false, page: false
    end
  end

  resources do
    resource Logbook
  end
end

Application.put_env(
  :ash_grpc,
  :proto_output,
  Path.join(System.tmp_dir!(), "ash_grpc_defaults_#{System.unique_integer([:positive])}")
)

defmodule AshGrpc.TestSupport.DefaultsEndpoint do
  @moduledoc false
  use AshGrpc.Endpoint,
    domains: [AshGrpc.TestSupport.Defaults],
    authenticator: AshGrpc.TestSupport.Authenticator
end

Application.delete_env(:ash_grpc, :proto_output)
