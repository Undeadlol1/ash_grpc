defmodule AshGrpc.TestSupport.Vault.Entry do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.TestSupport.Vault,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshGrpc.Resource]

  grpc do
    proto_message "Entry"
    fields id: 1, label: 2, account: 3
  end

  actions do
    defaults [:read, create: [:label, :memo, :account_id]]
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :label, :string, public?: true
    attribute :memo, :string, public?: true
  end

  relationships do
    belongs_to :account, AshGrpc.TestSupport.Vault.Account, public?: true
  end
end

defmodule AshGrpc.TestSupport.Vault.Account do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.TestSupport.Vault,
    data_layer: Ash.DataLayer.Ets,
    simple_notifiers: [AshGrpc.Notifier],
    extensions: [AshGrpc.Resource]

  grpc do
    proto_message "Account"
    fields id: 1, name: 2, entries: 3
  end

  actions do
    defaults [:read, create: [:name, :email, :api_token]]
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :name, :string, public?: true
    attribute :email, :string, public?: true
    attribute :api_token, :string, public?: true, sensitive?: true
  end

  relationships do
    has_many :entries, AshGrpc.TestSupport.Vault.Entry, public?: true
  end
end

defmodule AshGrpc.TestSupport.Vault do
  @moduledoc false
  use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

  alias AshGrpc.TestSupport.Vault.Account
  alias AshGrpc.TestSupport.Vault.Entry

  grpc do
    package "vault.v1"

    service "Vault" do
      rpc Account, :search_accounts, :read, sort: 1, filter: 2, page: false
      subscription Account, :watch_accounts, :read, sort: 1, filter: 2
    end
  end

  resources do
    resource Account
    resource Entry
  end
end

defmodule AshGrpc.TestSupport.VaultEndpoint do
  @moduledoc false
  use AshGrpc.Endpoint,
    domains: [AshGrpc.TestSupport.Vault],
    authenticator: AshGrpc.TestSupport.Authenticator
end
