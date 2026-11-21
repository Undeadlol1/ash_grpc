defmodule AshGrpc.TestSupport.Entry do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.TestSupport.Tallies,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshGrpc.Resource]

  grpc do
    proto_message "Entry"
    fields id: 1, amount: 2, label: 3, code: 4, codes: 5
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:amount, :label, :tally_id]
    end
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :amount, :integer, public?: true
    attribute :label, :string, public?: true
    attribute :code, :ci_string, public?: true
    attribute :codes, {:array, :ci_string}, public?: true
  end

  relationships do
    belongs_to :tally, AshGrpc.TestSupport.Tally, public?: true
  end
end

defmodule AshGrpc.TestSupport.Tally do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.TestSupport.Tallies,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshGrpc.Resource]

  grpc do
    proto_message "Tally"
    fields id: 1, name: 2, entry_count: 3, entry_total: 4, has_entries: 5, labels: 6
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:name]
    end

    action :shout, :string do
      argument :word, :string, allow_nil?: false
      run fn input, _context -> {:ok, String.upcase(input.arguments.word)} end
    end

    action :ping do
      run fn _input, _context -> :ok end
    end

    action :words, {:array, :string} do
      run fn _input, _context -> {:ok, ["a", "b"]} end
    end

    action :digest, :map do
      constraints fields: [
                    total: [type: :integer, allow_nil?: false],
                    note: [type: :string]
                  ]

      run fn _input, _context -> {:ok, %{total: 3, note: nil}} end
    end

    action :maybe_word, :string do
      allow_nil? true
      run fn _input, _context -> {:ok, nil} end
    end

    action :every_tally, {:array, :struct} do
      constraints items: [instance_of: __MODULE__]
      run fn _input, context -> Ash.read(__MODULE__, Ash.Context.to_opts(context)) end
    end
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :name, :string, public?: true
  end

  relationships do
    has_many :entries, AshGrpc.TestSupport.Entry, public?: true
  end

  aggregates do
    count :entry_count, :entries, public?: true
    sum :entry_total, :entries, :amount, public?: true
    exists :has_entries, :entries, public?: true
    list :labels, :entries, :label, public?: true
  end
end

defmodule AshGrpc.TestSupport.Tallies do
  @moduledoc false
  use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

  alias AshGrpc.TestSupport.Entry
  alias AshGrpc.TestSupport.Tally

  grpc do
    package "tallies.v1"

    service "Tallies" do
      rpc Tally, :list_tallies, :read, sort: false, filter: false, page: false

      rpc Tally, :create_tally, :create,
        args: [name: 1],
        sort: false,
        filter: false,
        page: false

      rpc Tally, :shout, :shout,
        args: [word: 1],
        sort: false,
        filter: false,
        page: false

      rpc Tally, :ping, :ping, sort: false, filter: false, page: false
      rpc Tally, :words, :words, sort: false, filter: false, page: false
      rpc Tally, :digest, :digest, sort: false, filter: false, page: false

      rpc Tally, :maybe_word, :maybe_word,
        sort: false,
        filter: false,
        page: false

      rpc Tally, :every_tally, :every_tally,
        sort: false,
        filter: false,
        page: false

      rpc Entry, :list_entries, :read, sort: false, filter: false, page: false

      rpc Entry, :create_entry, :create,
        sort: false,
        filter: false,
        page: false,
        args: [tally_id: 1, amount: 2, label: 3]
    end
  end

  resources do
    resource Tally
    resource Entry
  end
end

defmodule AshGrpc.TestSupport.TalliesEndpoint do
  @moduledoc false
  use AshGrpc.Endpoint,
    domains: [AshGrpc.TestSupport.Tallies],
    authenticator: AshGrpc.TestSupport.Authenticator
end
