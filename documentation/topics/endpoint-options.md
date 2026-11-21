# Endpoint options

Options of the endpoint, one section each: TLS, health checks, compression,
server reflection and calling from a browser.

## TLS

An endpoint serves plaintext unless you give it a certificate. The start
options go to `GRPC.Server.Supervisor`, so pass a credential through
`adapter_opts`:

    {MyApp.GrpcEndpoint,
     port: 50051,
     adapter_opts: [
       cred: GRPC.Credential.new(ssl: [certfile: "priv/cert.pem", keyfile: "priv/key.pem"])
     ]}

The `ssl` list takes any Erlang `:ssl` server option (`cert` and `key` with DER
values work too). The endpoint advertises HTTP/2 itself.

A client connects with `https://` and a credential that trusts the certificate:

    cred = GRPC.Credential.new(ssl: [cacertfile: "priv/ca.pem"])
    GRPC.Stub.connect("https://localhost:50051", cred: cred)

`grpcurl` needs no `-plaintext` flag; add `-cacert priv/ca.pem` for a private
certificate. A plaintext client cannot call a TLS endpoint.

Certificates must be signed with SHA-256 or stronger. If you terminate TLS at a
proxy instead, leave the option out and run the endpoint plaintext behind it.

## Health checks

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

## Compression

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

## Server reflection

Reflection lets `grpcurl` and Postman list and call your services without a
`.proto` file. It is off by default: it shows the whole schema to anyone who
can reach the port.

Add the package, then turn it on:

    {:grpc_reflection, "~> 0.5"}

    use AshGrpc.Endpoint,
      domains: [MyApp.Blog],
      authenticator: MyApp.GrpcAuthenticator,
      reflection: true

Without the package, `reflection: true` stops the build and says what to add.
The endpoint serves the v1 and v1alpha reflection services and starts the
reflection supervisor itself.

Reflection calls go through your authenticator like every other call, so send
the same header:

    grpcurl -plaintext -H 'authorization: Bearer TOKEN' localhost:50051 list
    grpcurl -plaintext -H 'authorization: Bearer TOKEN' localhost:50051 describe blog.v1.Post
    grpcurl -plaintext -H 'authorization: Bearer TOKEN' -d '{}' localhost:50051 blog.v1.Posts/ListPosts

With `health: true` as well, the health service is listed too, and
`grpcurl -plaintext -H 'authorization: Bearer TOKEN' localhost:50051 grpc.health.v1.Health/Check`
works (the reflection lookup needs the header; the check itself does not).

In Postman, add the `authorization` metadata and use "Use server reflection".

Keep it off in production unless exposing the schema to authenticated callers
is intended. With the option off, a call to the reflection service gets no
route (HTTP 404).

## Calling from a browser (gRPC-Web)

The server already speaks gRPC-Web. A browser on another origin also needs CORS,
which the `:cors` option adds:

    use AshGrpc.Endpoint,
      domains: [MyApp.Blog],
      authenticator: MyApp.GrpcAuthenticator,
      cors: [allow_origin: "https://app.example.com"]

`allow_origin` is a string, or a `&Mod.fun/2` capture that gets the request and
the stream and returns the origin to allow (return `"null"` to allow none).
Without `:cors` nothing changes.

With it on:

  * CORS headers are set before authentication, so they are on successful calls
    and on refused ones (`UNAUTHENTICATED`, `INVALID_ARGUMENT`...).
  * A preflight (`OPTIONS`) is answered at once. The authenticator, the
    interceptors and the action never run for it.
  * The browser can read an error: over gRPC-Web the status is in the trailer
    frame at the end of the body (flag byte `0x80`, lines `grpc-status: 16`,
    `grpc-message: ...`) and the HTTP status is 200. No header has to be exposed.

A browser preflight has no `content-type`, so the server adapter logs a warning
("Received invalid content-type") for each one.
