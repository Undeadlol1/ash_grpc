defmodule AshGrpc.TestSupport.MetaEndpoint do
  @moduledoc false
  use AshGrpc.Endpoint,
    domains: [AshGrpc.TestSupport.Blog],
    authenticator: AshGrpc.TestSupport.Authenticator,
    response_meta: true,
    interceptors: [
      {AshGrpc.TestSupport.MetaInterceptor, name: "outer"},
      {AshGrpc.TestSupport.MetaInterceptor, name: "inner"}
    ]
end
