defmodule AshGrpc.Support.V1.SubmitTicketRequest do
  @moduledoc false
  use Protobuf,
    syntax: :proto3,
    full_name: "ash_grpc.support.v1.SubmitTicketRequest"

  field(:subject, 1, type: :string)
  field(:body, 2, type: :string)
end

defmodule AshGrpc.Support.V1.CloseTicketRequest do
  @moduledoc false
  use Protobuf,
    syntax: :proto3,
    full_name: "ash_grpc.support.v1.CloseTicketRequest"

  field(:ticket_id, 1, type: :string)
end

defmodule AshGrpc.Support.V1.ListTicketsRequest do
  @moduledoc false
  use Protobuf,
    syntax: :proto3,
    full_name: "ash_grpc.support.v1.ListTicketsRequest"
end

defmodule AshGrpc.Support.V1.SubmitTicketBatchReply do
  @moduledoc false
  use Protobuf,
    syntax: :proto3,
    full_name: "ash_grpc.support.v1.SubmitTicketBatchReply"

  field(:submitted_count, 1, type: :int32)
end

defmodule AshGrpc.Support.V1.SubmitTicketReply do
  @moduledoc false
  use Protobuf,
    syntax: :proto3,
    full_name: "ash_grpc.support.v1.SubmitTicketReply"

  field(:ticket_id, 1, type: :string)
  field(:status, 2, type: :string)
end

defmodule AshGrpc.Support.V1.RequestMapper do
  @moduledoc false

  alias AshGrpc.Support.V1.SubmitTicketRequest

  @spec to_ash_input(SubmitTicketRequest.t()) :: {:ok, [String.t()]} | {:error, term()}
  def to_ash_input(%SubmitTicketRequest{subject: subject, body: body})
      when is_binary(subject) and subject != "" and is_binary(body) and body != "" do
    {:ok, [subject, body]}
  end

  def to_ash_input(%SubmitTicketRequest{}),
    do: {:error, %{code: :invalid_argument, message: "subject and body are required"}}
end

defmodule AshGrpc.Support.V1.CloseTicketRequestMapper do
  @moduledoc false

  alias AshGrpc.Examples.SupportDesk
  alias AshGrpc.Examples.SupportTicket
  alias AshGrpc.Support.V1.CloseTicketRequest

  @spec to_ash_input(CloseTicketRequest.t()) :: {:ok, SupportTicket.t()} | {:error, term()}
  def to_ash_input(%CloseTicketRequest{ticket_id: ticket_id})
      when is_binary(ticket_id) and ticket_id != "" do
    SupportDesk.get_ticket(ticket_id)
  end

  def to_ash_input(%CloseTicketRequest{}),
    do: {:error, %{code: :invalid_argument, message: "ticket_id is required"}}
end

defmodule AshGrpc.Support.V1.ListTicketsRequestMapper do
  @moduledoc false

  alias AshGrpc.Support.V1.ListTicketsRequest

  @spec to_ash_input(ListTicketsRequest.t()) :: {:ok, list()}
  def to_ash_input(%ListTicketsRequest{}), do: {:ok, []}
end

defmodule AshGrpc.Support.V1.SubmitTicketStreamRequestMapper do
  @moduledoc false

  alias AshGrpc.Support.V1.RequestMapper
  alias AshGrpc.Support.V1.SubmitTicketRequest

  @spec to_ash_input(Enumerable.t()) :: {:ok, Enumerable.t()}
  def to_ash_input(requests) do
    {:ok,
     Stream.map(requests, fn
       %SubmitTicketRequest{} = request ->
         case RequestMapper.to_ash_input(request) do
           {:ok, ash_input} -> ash_input
           {:error, error} -> {:error, error}
         end
     end)}
  end
end

defmodule AshGrpc.Support.V1.ResponseMapper do
  @moduledoc false

  alias AshGrpc.Examples.SupportTicket
  alias AshGrpc.Support.V1.SubmitTicketReply

  @spec to_response(SupportTicket.t()) :: {:ok, SubmitTicketReply.t()} | {:error, term()}
  def to_response(%SupportTicket{id: id, status: status}) when is_binary(id) do
    status =
      case status do
        :open -> "submitted"
        :triaged -> "submitted"
        :awaiting_confirmation -> "submitted"
        :closed -> "closed"
      end

    {:ok, %SubmitTicketReply{ticket_id: id, status: status}}
  end
end

defmodule AshGrpc.Support.V1.SubmitTicketBatchResponseMapper do
  @moduledoc false

  alias AshGrpc.Support.V1.SubmitTicketBatchReply

  @spec to_response(map()) :: {:ok, SubmitTicketBatchReply.t()}
  def to_response(%{submitted_count: submitted_count}) when is_integer(submitted_count) do
    {:ok, %SubmitTicketBatchReply{submitted_count: submitted_count}}
  end
end

defmodule AshGrpc.Support.V1.Tickets.Service do
  @moduledoc false
  use GRPC.Service, name: "ash_grpc.support.v1.Tickets"

  alias AshGrpc.Support.V1.ListTicketsRequest
  alias AshGrpc.Support.V1.SubmitTicketBatchReply
  alias AshGrpc.Support.V1.SubmitTicketReply
  alias AshGrpc.Support.V1.SubmitTicketRequest

  rpc(:SubmitTicket, SubmitTicketRequest, SubmitTicketReply)
  rpc(:CloseTicket, AshGrpc.Support.V1.CloseTicketRequest, SubmitTicketReply)
  rpc(:StreamTickets, ListTicketsRequest, stream(SubmitTicketReply))
  rpc(:SubmitTicketBatch, stream(SubmitTicketRequest), SubmitTicketBatchReply)
  rpc(:SyncTickets, stream(SubmitTicketRequest), stream(SubmitTicketReply))
end

defmodule AshGrpc.Support.V1.Tickets.Server do
  @moduledoc false
  use GRPC.Server, service: AshGrpc.Support.V1.Tickets.Service

  alias AshGrpc.Examples.SupportDesk
  alias AshGrpc.Support.V1.CloseTicketRequest
  alias AshGrpc.Support.V1.ListTicketsRequest
  alias AshGrpc.Support.V1.SubmitTicketRequest

  def submit_ticket(%SubmitTicketRequest{} = request, stream) do
    SupportDesk
    |> AshGrpc.Transport.handle_unary(:submit_ticket, request, grpc_stream: stream)
    |> AshGrpc.Transport.unwrap_response()
  end

  def close_ticket(%CloseTicketRequest{ticket_id: ticket_id}, stream) do
    SupportDesk
    |> AshGrpc.Transport.handle_unary(
      :close_ticket,
      %CloseTicketRequest{ticket_id: ticket_id},
      grpc_stream: stream
    )
    |> AshGrpc.Transport.unwrap_response()
  end

  def stream_tickets(%ListTicketsRequest{} = request, stream) do
    AshGrpc.Transport.handle_server_stream(
      SupportDesk,
      :stream_tickets,
      request,
      stream
    )
  end

  def submit_ticket_batch(requests, stream) do
    SupportDesk
    |> AshGrpc.Transport.handle_client_stream(:submit_ticket_batch, requests, grpc_stream: stream)
    |> AshGrpc.Transport.unwrap_response()
  end

  def sync_tickets(requests, stream) do
    AshGrpc.Transport.handle_bidirectional_stream(
      SupportDesk,
      :sync_tickets,
      requests,
      stream
    )
  end
end

defmodule AshGrpc.Support.V1.TransportOptions.EchoOptionsRequest do
  @moduledoc false
  use Protobuf,
    syntax: :proto3,
    full_name: "ash_grpc.support.v1.TransportOptions.EchoOptionsRequest"

  field(:payload, 1, type: :string)
end

defmodule AshGrpc.Support.V1.TransportOptions.EchoOptionsReply do
  @moduledoc false
  use Protobuf,
    syntax: :proto3,
    full_name: "ash_grpc.support.v1.TransportOptions.EchoOptionsReply"

  field(:payload, 1, type: :string)
  field(:actor_id, 2, type: :string)
  field(:authorize, 3, type: :bool)
  field(:tenant, 4, type: :string)
  field(:context_locale, 5, type: :string)
  field(:context_request_id, 6, type: :string)
end

defmodule AshGrpc.LiveTransportOptions do
  @moduledoc false

  use Ash.Domain,
    validate_config_inclusion?: false,
    extensions: [AshGrpc.Domain]

  alias AshGrpc.Examples.SupportTicket

  grpc do
    routes do
      service "/transport_options" do
        unary(:echo_options, SupportTicket, :create,
          handler: AshGrpc.LiveTransportOptionsHandler,
          request_mapper: AshGrpc.LiveTransportOptionsRequestMapper,
          response_mapper: AshGrpc.LiveTransportOptionsResponseMapper
        )
      end
    end
  end

  resources do
    resource(SupportTicket)
  end
end

defmodule AshGrpc.LiveTransportOptionsHandler do
  @moduledoc false

  def echo_options(request, opts \\ []) do
    {:ok, %{request: request, opts: opts}}
  end
end

defmodule AshGrpc.LiveTransportOptionsRequestMapper do
  @moduledoc false

  alias AshGrpc.Support.V1.TransportOptions.EchoOptionsRequest

  def to_ash_input(%EchoOptionsRequest{payload: payload}), do: {:ok, %{payload: payload}}
end

defmodule AshGrpc.LiveTransportOptionsResponseMapper do
  @moduledoc false

  alias AshGrpc.Support.V1.TransportOptions.EchoOptionsReply

  def to_response(%{request: %{payload: payload}, opts: opts}) do
    context = Keyword.get(opts, :context) || %{}
    actor = Keyword.get(opts, :actor) || %{}

    {:ok,
     %EchoOptionsReply{
       actor_id: Map.get(actor, :id) || Map.get(actor, "id") || "",
       authorize: Keyword.get(opts, :authorize?, false),
       context_locale: Map.get(context, "locale", ""),
       context_request_id: Map.get(context, "request_id", ""),
       payload: payload,
       tenant: Keyword.get(opts, :tenant, "")
     }}
  end
end

defmodule AshGrpc.Support.V1.TransportOptions.Service do
  @moduledoc false
  use GRPC.Service, name: "ash_grpc.support.v1.TransportOptions"

  alias AshGrpc.Support.V1.TransportOptions.EchoOptionsReply
  alias AshGrpc.Support.V1.TransportOptions.EchoOptionsRequest

  rpc(:EchoOptions, EchoOptionsRequest, EchoOptionsReply)
end

defmodule AshGrpc.Support.V1.TransportOptions.Server do
  @moduledoc false
  use GRPC.Server, service: AshGrpc.Support.V1.TransportOptions.Service

  alias AshGrpc.LiveTransportOptions
  alias AshGrpc.Support.V1.TransportOptions.EchoOptionsRequest

  def echo_options(%EchoOptionsRequest{} = request, stream) do
    # trust_request_metadata is only safe behind an authenticated internal
    # gateway; this endpoint exists to exercise the metadata mapping path.
    LiveTransportOptions
    |> AshGrpc.Transport.handle_unary(:echo_options, request,
      actor_resolver: AshGrpc.Support.V1.TransportOptions.ActorResolver,
      grpc_stream: stream,
      trust_request_metadata: true
    )
    |> AshGrpc.Transport.unwrap_response()
  end
end

defmodule AshGrpc.Support.V1.TransportOptions.Stub do
  @moduledoc false
  use GRPC.Stub, service: AshGrpc.Support.V1.TransportOptions.Service
end

defmodule AshGrpc.Support.V1.TransportOptions.ActorResolver do
  @moduledoc false

  def resolve(%{"id" => actor_id}) when is_binary(actor_id), do: {:ok, %{id: actor_id}}
end

defmodule AshGrpc.Support.V1.Tickets.Stub do
  @moduledoc false
  use GRPC.Stub, service: AshGrpc.Support.V1.Tickets.Service
end

defmodule AshGrpc.Router do
  use GRPC.Endpoint

  run(AshGrpc.Support.V1.Tickets.Server)
  run(AshGrpc.Support.V1.TransportOptions.Server)
  run(AshGrpc.Reflection.Server)
end
