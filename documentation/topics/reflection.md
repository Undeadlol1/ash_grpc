# Server reflection

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
