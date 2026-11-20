# Compression

An endpoint refuses a call that arrives compressed unless it knows the
compressor. Name the compressors it accepts:

    use AshGrpc.Endpoint,
      domains: [MyApp.Blog],
      authenticator: MyApp.GrpcAuthenticator,
      compressors: [GRPC.Compressor.Gzip]

A client that sends `grpc-encoding: gzip` is understood, and the response comes
back gzip-encoded with the same `grpc-encoding` header. A client that sends no
encoding gets plain responses. The default is `[]`: no compression, and a call
that asks for gzip answers `UNIMPLEMENTED`.

    {:ok, channel} = GRPC.Stub.connect("localhost:50051", compressor: GRPC.Compressor.Gzip)

`compressors` takes any module that implements `GRPC.Compressor`. The health
service does not take part: a probe never asks for compression.
