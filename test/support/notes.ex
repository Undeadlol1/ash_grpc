defmodule AshGrpc.TestSupport.Note do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.TestSupport.Notes,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    simple_notifiers: [AshGrpc.Notifier],
    extensions: [AshGrpc.Resource]

  grpc do
    proto_message "Note"
    fields id: 1, title: 2, author: 3, title_length: 4
  end

  actions do
    defaults [:read, :destroy, create: [:title, :author], update: [:title, :author]]

    read :matching do
      argument :word, :string, allow_nil?: false
      filter expr(contains(title, ^arg(:word)))
    end

    read :slow do
      prepare fn query, _context ->
        Ash.Query.after_action(query, fn _query, notes ->
          if Enum.any?(notes, &(&1.title == "slow")), do: Process.sleep(300)
          {:ok, notes}
        end)
      end
    end

    read :exploding do
      prepare fn query, _context ->
        Ash.Query.after_action(query, fn _query, notes ->
          if Enum.any?(notes, &(&1.title == "boom")),
            do: raise("disk on fire"),
            else: {:ok, notes}
        end)
      end
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(author == ^actor(:name))
    end

    policy always() do
      authorize_if always()
    end
  end

  multitenancy do
    strategy :attribute
    attribute :organization
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :author, :string, allow_nil?: false, public?: true
    attribute :organization, :string, allow_nil?: false, public?: true
  end

  calculations do
    calculate :title_length, :integer, expr(string_length(title)), public?: true
  end
end

defmodule AshGrpc.TestSupport.Organization do
  @moduledoc false
  defstruct [:slug]

  defimpl Ash.ToTenant do
    def to_tenant(%{slug: slug}, _resource), do: slug
  end
end

defmodule AshGrpc.TestSupport.Notes do
  @moduledoc false
  use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

  alias AshGrpc.TestSupport.Note

  grpc do
    package "notes.v1"

    service "Notes" do
      rpc Note, :list_notes, :read, sort: false, filter: false, page: false
      subscription Note, :watch_notes, :read, sort: false, filter: false
      subscription Note, :watch_matching, :matching, args: [word: 1], sort: false, filter: false
      subscription Note, :watch_sorted, :read, sort: 1, filter: false
      subscription Note, :watch_slow, :slow, sort: false, filter: false
      subscription Note, :watch_exploding, :exploding, sort: false, filter: false
    end
  end

  resources do
    resource Note
  end
end

defmodule AshGrpc.TestSupport.NotesEndpoint do
  @moduledoc false
  use AshGrpc.Endpoint,
    domains: [AshGrpc.TestSupport.Notes],
    authenticator: AshGrpc.TestSupport.Authenticator
end

defmodule AshGrpc.TestSupport.CappedNotesEndpoint do
  @moduledoc false
  use AshGrpc.Endpoint,
    domains: [AshGrpc.TestSupport.Notes],
    authenticator: AshGrpc.TestSupport.Authenticator,
    max_subscriptions: 2
end
