# Streaming calls

A streaming call lets the client send many messages on one open call. Each
message runs the action once, exactly like a unary call. Turn it on per rpc:

    rpc Entry, :post_entries, :create, streaming: :bidirectional, args: [title: 1]
    rpc Entry, :import_entries, :create, streaming: :client, args: [title: 1]

The request message is the same one the unary rpc would have. The call is
a stream of it.

## Bidirectional: one reply per message

With `streaming: :bidirectional` every message is answered at once, in order.
Use it for a confirmation per item, or a live search where each keystroke is a
message and each answer is a result list.

    rpc PostEntries(stream PostEntriesRequest) returns (stream PostEntriesReply);

    message PostEntriesReply {
      uint32 index = 1;
      oneof outcome {
        PostEntriesResponse result = 2;
        google.rpc.Status error = 3;
      }
    }

`index` counts the client's messages from 0. The reply holds either the
`result` (the same response message a unary call returns) or an `error`. Any
action type works, reads included.

## Client: one summary at the end

With `streaming: :client` the server stays quiet until the client is done, then
sends one summary. Use it when a phone that was offline sends its queued
records: "28 saved, 2 refused and why".

    rpc ImportEntries(stream ImportEntriesRequest) returns (ImportEntriesSummary);

    message ImportEntriesSummary {
      uint32 succeeded = 1;
      repeated ImportEntriesFailure failures = 2;
    }

    message ImportEntriesFailure {
      uint32 index = 1;
      google.rpc.Status error = 2;
    }

`succeeded` counts the saved messages. Each failure names the message `index`
and holds the error. The action must write: a read action stops the build.

## Each message stands alone

- The action runs once per message with the same actor, tenant, policies,
  inputs and errors as a unary call.
- A refused message does not end the stream and does not undo earlier ones.
  Nothing is all-or-nothing; for that use [bulk calls](bulk-calls.md).
- Nothing is buffered on the server. Messages are handled as they arrive.

## Errors

The `error` is a `google.rpc.Status` with the same code, message and details a
unary call would raise (see [Errors](errors.md)), so a field violation still
names the field.

Generated protos import `google/rpc/status.proto`; see
[Generating clients](generating-clients.md).

## Limits

`max_stream_failures` (default 100) caps the failures a `:client` call reports.
One more ends the call with `RESOURCE_EXHAUSTED`. Messages already saved stay
saved.

    rpc Entry, :import_entries, :create, streaming: :client, max_stream_failures: 20, args: [title: 1]

## How a stream ends

- The client half-closes: the server sends the summary (`:client`) or ends the
  reply stream (`:bidirectional`).
- The connection drops: processing stops. Earlier messages stay saved.
- The call deadline covers the whole stream. When it passes, the call ends with
  `DEADLINE_EXCEEDED`.

## What is not allowed

The build stops when you combine `streaming` with `bulk?`, use
`streaming: :client` on a read action, or set `max_stream_failures` without
`streaming: :client`. A subscription is its own kind of call.

## When to use something else

- All-or-nothing in one transaction: [bulk calls](bulk-calls.md).
- The server pushing live lists to the client: [subscriptions](subscriptions.md).
- Messages that only make sense together, such as file chunks, are not
  supported: every message is a call of its own.
