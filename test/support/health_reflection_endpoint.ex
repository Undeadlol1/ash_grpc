defmodule AshGrpc.TestSupport.HealthReflectionEndpoint do
  @moduledoc false
  use AshGrpc.Endpoint,
    domains: [AshGrpc.TestSupport.Blog],
    authenticator: AshGrpc.TestSupport.Authenticator,
    health: true,
    reflection: true
end
