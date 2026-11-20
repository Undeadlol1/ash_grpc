defmodule AshGrpc.TestSupport.CompressedEndpoint do
  @moduledoc false
  use AshGrpc.Endpoint,
    domains: [AshGrpc.TestSupport.Blog],
    authenticator: AshGrpc.TestSupport.Authenticator,
    compressors: [GRPC.Compressor.Gzip]
end
