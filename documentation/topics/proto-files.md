# Generating .proto files

`AshGrpc.Reflection` serves descriptors at runtime. To generate a client in
another language, write them to `.proto` files:

```
mix ash_grpc.gen.protos \
  --domain MyApp.Support \
  --service MyApp.Support.V1.Tickets.Service \
  --output priv/protos
```

Files are laid out by package path, for example
`priv/protos/my_app/support/v1/tickets.proto`. `--service` can be repeated.

Add `--check` in CI to fail when the files on disk differ from the routes.
