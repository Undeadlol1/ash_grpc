defmodule AshGrpc.Domain.Service do
  @moduledoc "A `service` entry of a domain's `grpc` block."
  alias AshGrpc.Domain.Rpc

  defstruct [:name, rpcs: [], subscriptions: [], __spark_metadata__: nil]

  @type t :: %__MODULE__{
          name: String.t(),
          rpcs: [Rpc.t()],
          subscriptions: [Rpc.t()]
        }
end
