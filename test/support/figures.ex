defmodule AshGrpc.TestSupport.Circle do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, extensions: [AshGrpc.Resource]

  grpc do
    proto_message "Circle"
    fields radius: 1
  end

  attributes do
    attribute :radius, :integer, allow_nil?: false, public?: true
  end
end

defmodule AshGrpc.TestSupport.Square do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, extensions: [AshGrpc.Resource]

  grpc do
    proto_message "Square"
    fields side: 1
  end

  attributes do
    attribute :side, :integer, allow_nil?: false, public?: true
  end
end

defmodule AshGrpc.TestSupport.Remark do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :union,
    constraints: [
      types: [
        words: [type: :string],
        stars: [type: :integer]
      ]
    ]
end

defmodule AshGrpc.TestSupport.Figure do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.TestSupport.Figures,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrpc.Resource]

  alias AshGrpc.TestSupport.Circle
  alias AshGrpc.TestSupport.Square

  @members [:measure, :shape, :pet, :remark, :shapes]

  grpc do
    proto_message "Figure"
    fields id: 1, measure: 2, shape: 3, pet: 4, remark: 5, shapes: 6
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept @members
    end

    update :update do
      primary? true
      accept @members
    end

    create :measure do
      argument :extra, :union,
        constraints: [types: [text: [type: :string], count: [type: :integer]]]

      change set_attribute(:measure, arg(:extra))
    end
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id, public?: true

    attribute :measure, :union,
      constraints: [
        types: [
          text: [type: :string],
          count: [type: :integer, constraints: [min: 0]],
          flag: [type: :boolean]
        ]
      ],
      public?: true

    attribute :shape, :union,
      constraints: [
        types: [
          circle: [type: Circle],
          square: [type: Square],
          box: [type: :map, constraints: [fields: [height: [type: :integer]]]]
        ]
      ],
      public?: true

    attribute :pet, :union,
      constraints: [
        types: [
          dog: [
            type: :map,
            constraints: [fields: [kind: [type: :string], name: [type: :string]]],
            tag: :kind,
            tag_value: "dog"
          ],
          cat: [
            type: :map,
            constraints: [fields: [kind: [type: :string], lives: [type: :integer]]],
            tag: :kind,
            tag_value: "cat"
          ]
        ]
      ],
      public?: true

    attribute :remark, AshGrpc.TestSupport.Remark, public?: true

    attribute :shapes, {:array, :union},
      constraints: [
        items: [
          types: [
            circle: [type: Circle],
            square: [type: Square]
          ]
        ]
      ],
      public?: true
  end
end

defmodule AshGrpc.TestSupport.Figures do
  @moduledoc false
  use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

  alias AshGrpc.TestSupport.Figure

  grpc do
    package "figures.v1"

    service "Figures" do
      rpc Figure, :list_figures, :read, sort: false, filter: false, page: false

      rpc Figure, :create_figure, :create,
        sort: false,
        filter: false,
        page: false,
        args: [measure: 1, shape: 2, pet: 3, remark: 4, shapes: 5]

      rpc Figure, :update_figure, :update,
        sort: false,
        filter: false,
        page: false,
        args: [id: 1, measure: 2, shape: 3, pet: 4, remark: 5, shapes: 6],
        clear_fields: 7

      rpc Figure, :measure_figure, :measure,
        args: [extra: 1],
        sort: false,
        filter: false,
        page: false
    end
  end

  resources do
    resource Figure
  end
end

defmodule AshGrpc.TestSupport.FiguresEndpoint do
  @moduledoc false
  use AshGrpc.Endpoint,
    domains: [AshGrpc.TestSupport.Figures],
    authenticator: AshGrpc.TestSupport.Authenticator
end
