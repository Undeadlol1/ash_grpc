# Streaming

`server_stream`, `client_stream` and `bidirectional_stream` routes always need
explicit `request_mapper` and `response_mapper` modules. Client and
bidirectional routes also take a `handler:` module whose function (named
after the route) receives the mapped requests as an enumerable.

```elixir
bidirectional_stream :sync_tickets, MyApp.Support.Ticket, :create,
  handler: MyApp.Support.Streaming,
  request_mapper: MyApp.Support.StreamRequestMapper,
  response_mapper: MyApp.Support.ReplyMapper
```

In the generated server module, call the matching `AshGrpc.Transport`
function: `handle_server_stream/5`, `handle_client_stream/4` or
`handle_bidirectional_stream/5`.

Server streams stop emitting when the client's `grpc-timeout` deadline passes.

## Live updates

`AshGrpc.NotifierStream.stream/2` builds a lazy stream from an event source,
and `AshGrpc.PubSubSource` is a source for Phoenix PubSub broadcasts:

```elixir
def stream_updates(%{user: user}) do
  {:ok,
   AshGrpc.NotifierStream.stream(AshGrpc.PubSubSource,
     pubsub: MyApp.PubSub,
     topic: "updates:#{user.id}",
     event: "sync",
     timeout: :infinity
   )}
end
```

Long-lived subscriptions must pass `timeout: :infinity`; otherwise the stream
ends after the idle window. Pass `limit:` to end it after that many messages.
Write your own source by implementing the `AshGrpc.NotifierStream.Source`
callbacks (`subscribe/1`, `handle_message/2`, `unsubscribe/1`).
