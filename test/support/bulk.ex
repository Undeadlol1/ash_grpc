defmodule AshGrpc.TestSupport.Memo do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.TestSupport.Bulks,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    simple_notifiers: [AshGrpc.Notifier],
    extensions: [AshGrpc.Resource]

  grpc do
    proto_message "Memo"
    fields id: 1, title: 2, owner: 3, archived: 4
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:title]
      change set_attribute(:owner, actor(:name))
    end

    update :archive do
      accept []
      change set_attribute(:archived, true)
    end

    update :retitle do
      accept [:title]
    end

    destroy :destroy do
      primary? true
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(owner == ^actor(:name))
    end

    policy action(:create) do
      forbid_if actor_attribute_equals(:name, "banned")
      authorize_if actor_present()
    end

    policy action_type(:update) do
      authorize_if actor_present()
    end

    policy action_type(:destroy) do
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end

  validations do
    validate string_length(:title, min: 3)
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :owner, :string, public?: true
    attribute :archived, :boolean, allow_nil?: false, default: false, public?: true
  end
end

defmodule AshGrpc.TestSupport.Seat do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.TestSupport.Bulks,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshGrpc.Resource]

  grpc do
    proto_message "Seat"
    fields row: 1, number: 2, holder: 3, tag: 4
  end

  actions do
    defaults [:read, :destroy, create: [:row, :number, :holder]]

    update :reserve do
      accept [:holder]
    end
  end

  attributes do
    attribute :row, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :number, :integer, primary_key?: true, allow_nil?: false, public?: true
    attribute :holder, :string, public?: true
  end

  calculations do
    calculate :tag, :string, expr(row <> "-" <> type(number, :string)), public?: true
  end
end

defmodule AshGrpc.TestSupport.Badge do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.TestSupport.Bulks,
    data_layer: Ash.DataLayer.Mnesia,
    extensions: [AshGrpc.Resource]

  mnesia do
    table :ash_grpc_test_badges
  end

  grpc do
    proto_message "Badge"
    fields id: 1, name: 2
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:name]

      change after_action(fn _changeset, badge, _context ->
               if badge.name == "boom",
                 do: {:error, "refused after earlier items were written"},
                 else: {:ok, badge}
             end)
    end
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
  end
end

defmodule AshGrpc.TestSupport.Bulks do
  @moduledoc false
  use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

  alias AshGrpc.TestSupport.Badge
  alias AshGrpc.TestSupport.Memo
  alias AshGrpc.TestSupport.Seat

  grpc do
    package "bulk.v1"

    service "Memos" do
      rpc Memo, :create_memos, :create, bulk?: true, args: [title: 1]
      rpc Memo, :create_few_memos, :create, bulk?: true, max_bulk_size: 2, args: [title: 1]
      rpc Memo, :archive_memos, :archive, bulk?: true, args: [id: 1]
      rpc Memo, :retitle_memos, :retitle, bulk?: true, args: [id: 1, title: 2]
      rpc Memo, :delete_memos, :destroy, bulk?: true, args: [id: 1]
      rpc Badge, :create_badges, :create, bulk?: true, max_bulk_size: 200, args: [name: 1]
      rpc Seat, :reserve_seats, :reserve, bulk?: true, args: [row: 1, number: 2, holder: 3]
      rpc Seat, :delete_seats, :destroy, bulk?: true, args: [row: 1, number: 2]
      subscription Memo, :watch_memos, :read, sort: false, filter: false
    end
  end

  resources do
    resource Badge
    resource Memo
    resource Seat
  end
end

defmodule AshGrpc.TestSupport.BulkEndpoint do
  @moduledoc false
  use AshGrpc.Endpoint,
    domains: [AshGrpc.TestSupport.Bulks],
    authenticator: AshGrpc.TestSupport.Authenticator
end
