# Errors

A failed call ends with a `GRPC.RPCError`. The client sees a status, a short
message and, for invalid input, details.

## Status mapping

| Cause | Status | Message |
|---|---|---|
| authenticator returned `{:error, :unauthenticated}` | `UNAUTHENTICATED` | `Unauthenticated` |
| authenticator returned `{:error, :unavailable}` | `UNAVAILABLE` | `Unavailable` |
| authenticator returned `{:error, {:unavailable, retry_after_ms}}` | `UNAVAILABLE` | `Unavailable`, with `grpc-retry-pushback-ms` |
| Ash invalid input | `INVALID_ARGUMENT` | `Invalid request`, with field violations |
| Ash forbidden | `PERMISSION_DENIED` | `Forbidden` |
| record not found | `NOT_FOUND` | `Not found` |
| client deadline passed | `DEADLINE_EXCEEDED` | `Deadline exceeded` |
| anything else | `INTERNAL` | `Internal error` |

Details:

- Not found covers a get read with no match, an update or destroy whose
  record is missing or not readable by the caller, and a generic action that
  returned `nil`.
- Not found and timeout win over other invalid errors in the same failure.
- A unique-constraint or identity violation is invalid input too: `INVALID_ARGUMENT` with a field violation. Ash gives no marker the library can rely on across data layers (a pre-checked identity and an ETS key clash are plain `InvalidChanges`, indistinguishable by structure from any other), so it is not told apart as `ALREADY_EXISTS`. An interceptor can map it itself.
- A value that cannot be decoded (a malformed uuid, decimal or date, a
  timestamp out of range) is invalid input.
- When an Ash failure holds both forbidden and invalid errors, Ash picks one
  class, and so the call gets one status.
- An interceptor can end a call with any status by raising a
  `GRPC.RPCError`. See [Interceptors and response meta](interceptors-and-response-meta.md).

## Field violations

`INVALID_ARGUMENT` carries a `google.protobuf.Any` of type
`type.googleapis.com/google.rpc.BadRequest`. It holds one `FieldViolation`
per field, with the field name and the error's own message. The message holds no Ash
bread crumbs and no resource or action names. An error that names
no field gets a violation with an empty field name.

After the `BadRequest`, each violation has a matching `google.rpc.ErrorInfo`
detail (same order). Its `reason` is the machine-readable error code: the Ash
error module's last name segment in snake_case, such as `required` or
`invalid_attribute`. Its `domain` is `ash` and `metadata["field"]` is the
violation's field path, so a client pairs the code with its field.

In Elixir:

```elixir
{:error, %GRPC.RPCError{status: status, details: [detail | _infos]}} =
  Stub.create_post(channel, %V1.CreatePostRequest{title: "ab"}, metadata: metadata)

status == GRPC.Status.invalid_argument()
#=> true

%Google.Rpc.BadRequest{field_violations: violations} =
  Google.Rpc.BadRequest.decode(detail.value)

[%{field: "title", description: description}] = violations
```

Other languages decode the same message with their generated
`google.rpc.BadRequest` type.

## What is logged

The client never sees the cause of an internal error: not the exception, not
its message, not a stacktrace. The server logs it once, at `error` level,
starting `AshGrpc request failed:`. A raise inside an action and a raise in the
authenticator are both handled this way.

Errors the library maps to a status are not logged by the server adapter.
