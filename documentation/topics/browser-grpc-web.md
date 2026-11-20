# Calling from a browser (gRPC-Web)

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
