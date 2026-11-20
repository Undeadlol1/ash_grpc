defmodule AshGrpc.Health do
  @moduledoc false

  @service_name "grpc.health.v1.Health"

  def service_name, do: @service_name

  defmodule ServingStatus do
    @moduledoc false
    use Protobuf,
      enum: true,
      full_name: "grpc.health.v1.HealthCheckResponse.ServingStatus",
      syntax: :proto3

    field :UNKNOWN, 0
    field :SERVING, 1
    field :NOT_SERVING, 2
    field :SERVICE_UNKNOWN, 3
  end

  defmodule HealthCheckRequest do
    @moduledoc false
    use Protobuf, full_name: "grpc.health.v1.HealthCheckRequest", syntax: :proto3

    field :service, 1, type: :string
  end

  defmodule HealthCheckResponse do
    @moduledoc false
    use Protobuf, full_name: "grpc.health.v1.HealthCheckResponse", syntax: :proto3

    alias Google.Protobuf.DescriptorProto
    alias Google.Protobuf.EnumDescriptorProto
    alias Google.Protobuf.EnumValueDescriptorProto
    alias Google.Protobuf.FieldDescriptorProto

    field :status, 1, type: AshGrpc.Health.ServingStatus, enum: true

    def descriptor do
      %DescriptorProto{
        name: "HealthCheckResponse",
        field: [
          %FieldDescriptorProto{
            name: "status",
            number: 1,
            label: :LABEL_OPTIONAL,
            type: :TYPE_ENUM,
            type_name: ".grpc.health.v1.HealthCheckResponse.ServingStatus",
            json_name: "status"
          }
        ],
        enum_type: [
          %EnumDescriptorProto{
            name: "ServingStatus",
            value:
              for {name, number} <- [UNKNOWN: 0, SERVING: 1, NOT_SERVING: 2, SERVICE_UNKNOWN: 3] do
                %EnumValueDescriptorProto{name: Atom.to_string(name), number: number}
              end
          }
        ]
      }
    end
  end

  defmodule Service do
    @moduledoc false
    use GRPC.Service, name: "grpc.health.v1.Health"

    alias AshGrpc.Health.HealthCheckRequest
    alias AshGrpc.Health.HealthCheckResponse

    rpc :Check, HealthCheckRequest, HealthCheckResponse
    rpc :Watch, HealthCheckRequest, stream(HealthCheckResponse)
  end

  defmodule Server do
    @moduledoc false
    use GRPC.Server, service: AshGrpc.Health.Service

    alias AshGrpc.Health.HealthCheckResponse

    def check(%{service: service}, stream) do
      if served?(service, stream) do
        %HealthCheckResponse{status: :SERVING}
      else
        raise GRPC.RPCError, status: :not_found, message: "unknown service #{service}"
      end
    end

    def watch(%{service: service}, stream) do
      status = if served?(service, stream), do: :SERVING, else: :SERVICE_UNKNOWN
      GRPC.Server.send_reply(stream, %HealthCheckResponse{status: status})

      receive do
        :never -> :ok
      end
    end

    defp served?("", _stream), do: true

    defp served?(service, %{endpoint: endpoint}) do
      Enum.any?(endpoint.__meta__(:servers), fn server ->
        server.__meta__(:service).__meta__(:name) == service
      end)
    end
  end
end
