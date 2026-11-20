defmodule AshGrpc.TestSupport.Mood do
  @moduledoc false
  use Ash.Type.Enum, values: [:calm, :wild]
end

defmodule AshGrpc.TestSupport.Finish do
  @moduledoc false
  use Ash.Type.Enum, values: [matte: "No shine", gloss: "A high shine"]
end

defmodule AshGrpc.TestSupport.Tier do
  @moduledoc false
  use Ash.Type.NewType, subtype_of: :atom, constraints: [one_of: [:basic, :pro]]
end

defmodule AshGrpc.TestSupport.Gadget do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.TestSupport.Gadgets,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshGrpc.Resource]

  alias AshGrpc.TestSupport.Finish
  alias AshGrpc.TestSupport.Mood

  grpc do
    proto_message "Gadget"
    fields id: 1, kind: 2, mood: 3, tier: 4, settings: 5, moods: 6, box: 7, pick: 8, finish: 9
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:kind, :mood, :tier, :settings, :moods, :box, :pick, :finish]
    end

    action :current_mood, Mood do
      run fn _input, _context -> {:ok, :wild} end
    end

    action :moods_today, {:array, Mood} do
      run fn _input, _context -> {:ok, [:calm, :wild]} end
    end

    action :echo_finish, Finish do
      argument :finish, Finish, allow_nil?: false
      run fn input, _context -> {:ok, input.arguments.finish} end
    end

    create :create_with_arguments do
      argument :kind, :atom, constraints: [one_of: [:lamp, :fan]], allow_nil?: false
      argument :mood, Mood
      argument :extra, :map
      change set_attribute(:kind, arg(:kind))
      change set_attribute(:mood, arg(:mood))
      change set_attribute(:settings, arg(:extra))
    end
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :kind, :atom, constraints: [one_of: [:lamp, :fan]], allow_nil?: false, public?: true
    attribute :mood, Mood, public?: true
    attribute :tier, AshGrpc.TestSupport.Tier, public?: true
    attribute :settings, :map, public?: true
    attribute :moods, {:array, Mood}, public?: true

    attribute :box, :map,
      public?: true,
      constraints: [
        fields: [
          shade: [type: :atom, constraints: [one_of: [:dark, :light]], allow_nil?: false],
          mood: [type: Mood]
        ]
      ]

    attribute :pick, :union,
      public?: true,
      constraints: [
        types: [
          feel: [type: Mood],
          count: [type: :integer]
        ]
      ]

    attribute :finish, Finish, public?: true
  end
end

defmodule AshGrpc.TestSupport.Gadgets do
  @moduledoc false
  use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

  alias AshGrpc.TestSupport.Gadget

  grpc do
    package "gadgets.v1"

    service "Gadgets" do
      rpc Gadget, :list_gadgets, :read, sort: false, filter: false, page: false

      rpc Gadget, :create_gadget, :create,
        sort: false,
        filter: false,
        page: false,
        args: [kind: 1, mood: 2, tier: 3, settings: 4, moods: 5, box: 6, pick: 7, finish: 8]

      rpc Gadget, :build_gadget, :create_with_arguments,
        args: [kind: 1, mood: 2, extra: 3],
        sort: false,
        filter: false,
        page: false

      rpc Gadget, :find_gadgets, :read, filter: 1, sort: false, page: false
      rpc Gadget, :current_mood, :current_mood, sort: false, filter: false, page: false
      rpc Gadget, :moods_today, :moods_today, sort: false, filter: false, page: false

      rpc Gadget, :echo_finish, :echo_finish,
        args: [finish: 1],
        sort: false,
        filter: false,
        page: false
    end
  end

  resources do
    resource Gadget
  end
end

defmodule AshGrpc.TestSupport.GadgetsEndpoint do
  @moduledoc false
  use AshGrpc.Endpoint,
    domains: [AshGrpc.TestSupport.Gadgets],
    authenticator: AshGrpc.TestSupport.Authenticator
end
