# TLS

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
