defmodule AshGrpc.TestSupport.HealthEndpoint do
  @moduledoc false
  use AshGrpc.Endpoint,
    domains: [AshGrpc.TestSupport.Blog, AshGrpc.TestSupport.Library],
    authenticator: AshGrpc.TestSupport.Authenticator,
    health: true
end
