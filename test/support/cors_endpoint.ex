defmodule AshGrpc.TestSupport.CorsEndpoint do
  @moduledoc false
  use AshGrpc.Endpoint,
    domains: [AshGrpc.TestSupport.Blog],
    authenticator: AshGrpc.TestSupport.Authenticator,
    cors: [allow_origin: "https://app.example.com"]
end

defmodule AshGrpc.TestSupport.CorsFunctionEndpoint do
  @moduledoc false
  use AshGrpc.Endpoint,
    domains: [AshGrpc.TestSupport.Blog],
    authenticator: AshGrpc.TestSupport.Authenticator,
    cors: [allow_origin: &AshGrpc.TestSupport.CorsFunctionEndpoint.allow_origin/2]

  def allow_origin(_request, stream) do
    case stream.http_request_headers["origin"] do
      "https://" <> _ = origin -> origin
      _other -> "null"
    end
  end
end
