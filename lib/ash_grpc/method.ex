defmodule AshGrpc.Method do
  @moduledoc """
  Explicit binding between one gRPC method and one Ash action.
  """

  defstruct [
    :domain,
    :handler,
    :name,
    :kind,
    :deprecated,
    :resource,
    :action,
    :request_mapper,
    :response_mapper,
    :runner,
    action_options: [],
    error_mapper: AshGrpc.ErrorMapper
  ]

  @type t :: %__MODULE__{
          domain: Ash.Domain.t() | module() | nil,
          handler: module() | nil,
          name: atom() | nil,
          kind: :unary | :server_stream | :client_stream | :bidirectional_stream | nil,
          deprecated: String.t() | nil,
          resource: Ash.Resource.t() | module(),
          action: atom(),
          request_mapper: module(),
          response_mapper: module(),
          runner: module(),
          action_options: keyword(),
          error_mapper: module()
        }

  @spec bind(keyword()) :: t()
  def bind(options) when is_list(options) do
    required_keys = [:resource, :action, :request_mapper, :response_mapper, :runner]
    missing_keys = Enum.filter(required_keys, &is_nil(Keyword.get(options, &1)))

    if missing_keys != [] do
      raise ArgumentError,
            "missing required ash_grpc binding options: #{Enum.join(missing_keys, ", ")}"
    end

    struct!(__MODULE__, options)
  end
end
