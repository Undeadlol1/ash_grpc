# Health checks

Load balancers and orchestrators (Kubernetes gRPC probes, `grpc_health_probe`,
Envoy) ask a server whether it is up through the standard
`grpc.health.v1.Health` service. It is off by default. Turn it on:

    use AshGrpc.Endpoint,
      domains: [MyApp.Blog],
      authenticator: MyApp.GrpcAuthenticator,
      health: true

Health calls skip your authenticator, so a probe needs no credentials. Your
interceptors still run, but `AshGrpc.Authenticator.fetch_opts/1` answers
`:error` for them.

`Check` with an empty service name, or the full name of a service the endpoint
serves (`blog.v1.Posts`), answers `SERVING`. Any other name answers
`NOT_FOUND`. `Watch` sends the current status once (`SERVICE_UNKNOWN` for an
unknown name) and stays open until the client leaves.

    grpcurl -plaintext localhost:50051 grpc.health.v1.Health/Check
    grpcurl -plaintext -d '{"service": "blog.v1.Posts"}' localhost:50051 grpc.health.v1.Health/Check

The answer means the endpoint is up. Statuses cannot be set by hand, and a
`NOT_SERVING` answer is never sent. Without `health: true`, a call to the
health service gets no route (HTTP 404).
