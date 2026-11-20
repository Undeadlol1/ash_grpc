defmodule AshGrpc.TestSupport.InterceptedEndpoint do
  @moduledoc false
  use AshGrpc.Endpoint,
    domains: [AshGrpc.TestSupport.Blog],
    authenticator: AshGrpc.TestSupport.Authenticator,
    interceptors: [
      {AshGrpc.TestSupport.RecordingInterceptor, name: "outer"},
      {AshGrpc.TestSupport.RecordingInterceptor, name: "inner"}
    ]
end
