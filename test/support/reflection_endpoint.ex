defmodule AshGrpc.TestSupport.ReflectionEndpoint do
  @moduledoc false
  use AshGrpc.Endpoint,
    domains: [AshGrpc.TestSupport.Blog, AshGrpc.TestSupport.Library],
    authenticator: AshGrpc.TestSupport.Authenticator,
    reflection: true
end
