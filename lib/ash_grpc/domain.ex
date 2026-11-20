defmodule AshGrpc.Domain do
  @moduledoc """
  Spark DSL extension that adds a `grpc do ... end` section to an Ash domain
  for declaring gRPC routes (`unary`, `server_stream`, `client_stream`,
  `bidirectional_stream`) bound to Ash actions.
  """

  @service %Spark.Dsl.Entity{
    name: :service,
    args: [:path],
    target: AshGrpc.Domain.Service,
    recursive_as: :routes,
    entities: [
      routes: [
        %Spark.Dsl.Entity{
          name: :unary,
          args: [:name, :resource, :action],
          target: AshGrpc.Domain.UnaryRoute,
          schema: [
            name: [
              type: :atom,
              required: true,
              doc: "The transport-level RPC function name"
            ],
            resource: [
              type: {:spark, Ash.Resource},
              required: true,
              doc: "The Ash resource that implements the RPC"
            ],
            action: [
              type: :atom,
              required: true,
              doc: "The Ash code interface action to invoke"
            ],
            request_mapper: [
              type: :atom,
              required: false,
              doc:
                "Optional module that maps a transport request into Ash input; unary routes default to conservative inferred mapping when omitted"
            ],
            response_mapper: [
              type: :atom,
              required: false,
              doc:
                "Optional module that maps an Ash result into a transport response; unary routes default to identity mapping when omitted"
            ],
            handler: [
              type: :atom,
              required: false,
              doc:
                "Optional module that handles the bound route instead of the domain code interface"
            ],
            deprecated: [
              type: :string,
              required: false,
              doc: "Optional deprecation guidance preserved in the ash_grpc route metadata"
            ]
          ]
        },
        %Spark.Dsl.Entity{
          name: :server_stream,
          args: [:name, :resource, :action],
          target: AshGrpc.Domain.ServerStreamRoute,
          schema: [
            name: [
              type: :atom,
              required: true,
              doc: "The transport-level RPC function name"
            ],
            resource: [
              type: {:spark, Ash.Resource},
              required: true,
              doc: "The Ash resource that implements the RPC"
            ],
            action: [
              type: :atom,
              required: true,
              doc: "The Ash code interface action to invoke"
            ],
            request_mapper: [
              type: :atom,
              required: true,
              doc: "The module that maps a transport request into Ash input"
            ],
            response_mapper: [
              type: :atom,
              required: true,
              doc: "The module that maps an Ash result into a transport response"
            ],
            handler: [
              type: :atom,
              required: false,
              doc:
                "Optional module that handles the bound route instead of the domain code interface"
            ],
            deprecated: [
              type: :string,
              required: false,
              doc: "Optional deprecation guidance preserved in the ash_grpc route metadata"
            ]
          ]
        },
        %Spark.Dsl.Entity{
          name: :client_stream,
          args: [:name, :resource, :action],
          target: AshGrpc.Domain.ClientStreamRoute,
          schema: [
            name: [
              type: :atom,
              required: true,
              doc: "The transport-level RPC function name"
            ],
            resource: [
              type: {:spark, Ash.Resource},
              required: true,
              doc: "The Ash resource that implements the RPC"
            ],
            action: [
              type: :atom,
              required: true,
              doc: "The Ash code interface action to invoke"
            ],
            request_mapper: [
              type: :atom,
              required: true,
              doc: "The module that maps a transport request into Ash input"
            ],
            response_mapper: [
              type: :atom,
              required: true,
              doc: "The module that maps an Ash result into a transport response"
            ],
            handler: [
              type: :atom,
              required: false,
              doc:
                "Optional module that handles the bound route instead of the domain code interface"
            ],
            deprecated: [
              type: :string,
              required: false,
              doc: "Optional deprecation guidance preserved in the ash_grpc route metadata"
            ]
          ]
        },
        %Spark.Dsl.Entity{
          name: :bidirectional_stream,
          args: [:name, :resource, :action],
          target: AshGrpc.Domain.BidirectionalStreamRoute,
          schema: [
            name: [
              type: :atom,
              required: true,
              doc: "The transport-level RPC function name"
            ],
            resource: [
              type: {:spark, Ash.Resource},
              required: true,
              doc: "The Ash resource that implements the RPC"
            ],
            action: [
              type: :atom,
              required: true,
              doc: "The Ash code interface action to invoke"
            ],
            request_mapper: [
              type: :atom,
              required: true,
              doc: "The module that maps a transport request into Ash input"
            ],
            response_mapper: [
              type: :atom,
              required: true,
              doc: "The module that maps an Ash result into a transport response"
            ],
            handler: [
              type: :atom,
              required: false,
              doc:
                "Optional module that handles the bound route instead of the domain code interface"
            ],
            deprecated: [
              type: :string,
              required: false,
              doc: "Optional deprecation guidance preserved in the ash_grpc route metadata"
            ]
          ]
        }
      ]
    ],
    schema: [
      path: [
        type: :string,
        required: true,
        doc: "The gRPC service path"
      ]
    ]
  }
  @routes %Spark.Dsl.Section{
    name: :routes,
    describe: "Grouped transport routes exposed by the domain",
    entities: [
      @service
    ]
  }
  @grpc %Spark.Dsl.Section{
    name: :grpc,
    describe: "gRPC transport declarations for a domain",
    examples: [
      """
      grpc do
        routes do
          service "/support" do
            unary :submit_ticket, MyApp.Support.Ticket, :create
          end
        end
      end
      """
    ],
    sections: [
      @routes
    ]
  }
  use Spark.Dsl.Extension, sections: [@grpc]

  defmodule Info do
    @moduledoc false

    alias Spark.Dsl.Extension

    def routes(domain) do
      Extension.get_entities(domain, [:grpc, :routes])
    end

    def unary_binding(domain, route_name, options) do
      binding(domain, route_name, options)
    end

    def binding(domain, route_name, options) do
      route = find_route!(domain, route_name)
      {request_mapper, response_mapper} = route_mappers(route)

      AshGrpc.Method.bind(
        domain: domain,
        name: route.name,
        handler: Map.get(route, :handler) || domain,
        kind: Map.fetch!(route, :method_kind),
        deprecated: Map.get(route, :deprecated),
        resource: route.resource,
        action: route.action,
        request_mapper: request_mapper,
        response_mapper: response_mapper,
        runner: Keyword.fetch!(options, :runner),
        action_options: action_options(options)
      )
    end

    defp route_mappers(%{method_kind: :unary} = route) do
      {
        Map.get(route, :request_mapper, AshGrpc.InferredRequestMapper) ||
          AshGrpc.InferredRequestMapper,
        Map.get(route, :response_mapper, AshGrpc.InferredResponseMapper) ||
          AshGrpc.InferredResponseMapper
      }
    end

    defp route_mappers(route) do
      {route.request_mapper, route.response_mapper}
    end

    defp action_options(options) do
      Keyword.take(options, [:actor, :authorize?, :tenant, :context, :scope, :tracer])
    end

    defp find_route!(domain, route_name) do
      domain
      |> routes()
      |> Enum.flat_map(& &1.routes)
      |> Enum.find(&(&1.name == route_name))
      |> case do
        nil -> raise ArgumentError, "unknown ash_grpc route: #{inspect(route_name)}"
        route -> route
      end
    end
  end

  defmodule Service do
    @moduledoc false
    defstruct [:path, routes: [], __spark_metadata__: nil]
  end

  defmodule UnaryRoute do
    @moduledoc false
    defstruct [
      :name,
      :resource,
      :action,
      :request_mapper,
      :response_mapper,
      :handler,
      :deprecated,
      __spark_metadata__: nil,
      method_kind: :unary
    ]
  end

  defmodule ServerStreamRoute do
    @moduledoc false
    defstruct [
      :name,
      :resource,
      :action,
      :request_mapper,
      :response_mapper,
      :handler,
      :deprecated,
      __spark_metadata__: nil,
      method_kind: :server_stream
    ]
  end

  defmodule ClientStreamRoute do
    @moduledoc false
    defstruct [
      :name,
      :resource,
      :action,
      :request_mapper,
      :response_mapper,
      :handler,
      :deprecated,
      __spark_metadata__: nil,
      method_kind: :client_stream
    ]
  end

  defmodule BidirectionalStreamRoute do
    @moduledoc false
    defstruct [
      :name,
      :resource,
      :action,
      :request_mapper,
      :response_mapper,
      :handler,
      :deprecated,
      __spark_metadata__: nil,
      method_kind: :bidirectional_stream
    ]
  end
end
