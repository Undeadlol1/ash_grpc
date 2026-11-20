defmodule AshGrpc.Reflection.Server do
  @moduledoc false

  use GrpcReflection.Server,
    version: :v1,
    services: [AshGrpc.Support.V1.Tickets.Service]
end
