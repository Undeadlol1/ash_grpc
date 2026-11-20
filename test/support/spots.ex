defmodule AshGrpc.TestSupport.Spot do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.TestSupport.Spots,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshGrpc.Resource]

  alias AshGrpc.TestSupport.Mood

  @point [
    x: [type: :integer, allow_nil?: false],
    y: [type: :integer, constraints: [max: 100]],
    note: [type: :string]
  ]

  grpc do
    proto_message "Spot"
    fields id: 1, point: 2, points: 3, grid: 4, cube: 5, moods: 6, lanes: 7
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:point, :points, :grid, :cube, :moods, :lanes]
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:point, :grid]
    end

    action :mirror_point, :tuple do
      constraints fields: @point
      argument :at, :tuple, constraints: [fields: @point], allow_nil?: false
      run fn input, _context -> {:ok, input.arguments.at} end
    end

    action :mirror_grid, {:array, {:array, :integer}} do
      argument :rows, {:array, {:array, :integer}}, allow_nil?: false
      run fn input, _context -> {:ok, input.arguments.rows} end
    end

    action :mirror_cube, {:array, {:array, {:array, :string}}} do
      argument :cells, {:array, {:array, {:array, :string}}}, allow_nil?: false
      run fn input, _context -> {:ok, input.arguments.cells} end
    end
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :point, :tuple, public?: true, constraints: [fields: @point]
    attribute :points, {:array, :tuple}, public?: true, constraints: [items: [fields: @point]]
    attribute :grid, {:array, {:array, :integer}}, public?: true, default: []
    attribute :cube, {:array, {:array, {:array, :string}}}, public?: true, default: []
    attribute :moods, {:array, {:array, Mood}}, public?: true, default: []

    attribute :lanes, {:array, {:array, :tuple}},
      public?: true,
      default: [],
      constraints: [items: [items: [fields: @point]]]
  end
end

defmodule AshGrpc.TestSupport.Spots do
  @moduledoc false
  use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

  alias AshGrpc.TestSupport.Spot

  grpc do
    package "spots.v1"

    service "Spots" do
      rpc Spot, :list_spots, :read, sort: false, filter: false, page: false

      rpc Spot, :create_spot, :create,
        args: [point: 1, points: 2, grid: 3, cube: 4, moods: 5, lanes: 6],
        sort: false,
        filter: false,
        page: false

      rpc Spot, :update_spot, :update,
        args: [id: 1, point: 2, grid: 3],
        clear_fields: 4,
        sort: false,
        filter: false,
        page: false

      rpc Spot, :mirror_point, :mirror_point,
        args: [at: 1],
        sort: false,
        filter: false,
        page: false

      rpc Spot, :mirror_grid, :mirror_grid,
        args: [rows: 1],
        sort: false,
        filter: false,
        page: false

      rpc Spot, :mirror_cube, :mirror_cube,
        args: [cells: 1],
        sort: false,
        filter: false,
        page: false
    end
  end

  resources do
    resource Spot
  end
end

defmodule AshGrpc.TestSupport.SpotsEndpoint do
  @moduledoc false
  use AshGrpc.Endpoint,
    domains: [AshGrpc.TestSupport.Spots],
    authenticator: AshGrpc.TestSupport.Authenticator
end
