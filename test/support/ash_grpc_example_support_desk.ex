defmodule AshGrpc.Examples.SupportDesk do
  @moduledoc false

  use Ash.Domain,
    validate_config_inclusion?: false,
    extensions: [AshGrpc.Domain]

  alias AshGrpc.Examples.SupportDeskStreaming
  alias AshGrpc.Examples.SupportTicket
  alias AshGrpc.Support.V1.CloseTicketRequestMapper
  alias AshGrpc.Support.V1.ListTicketsRequestMapper
  alias AshGrpc.Support.V1.ResponseMapper
  alias AshGrpc.Support.V1.SubmitTicketBatchResponseMapper
  alias AshGrpc.Support.V1.SubmitTicketStreamRequestMapper

  grpc do
    routes do
      service "/support" do
        unary(:submit_ticket, SupportTicket, :create, response_mapper: ResponseMapper)

        unary(:close_ticket, SupportTicket, :close,
          request_mapper: CloseTicketRequestMapper,
          response_mapper: ResponseMapper
        )

        server_stream(:stream_tickets, SupportTicket, :read,
          request_mapper: ListTicketsRequestMapper,
          response_mapper: ResponseMapper,
          deprecated: "use list_tickets_v2"
        )

        client_stream(:submit_ticket_batch, SupportTicket, :create,
          handler: SupportDeskStreaming,
          request_mapper: SubmitTicketStreamRequestMapper,
          response_mapper: SubmitTicketBatchResponseMapper
        )

        bidirectional_stream(:sync_tickets, SupportTicket, :create,
          handler: SupportDeskStreaming,
          request_mapper: SubmitTicketStreamRequestMapper,
          response_mapper: ResponseMapper
        )
      end
    end
  end

  resources do
    resource SupportTicket do
      define(:get_ticket, action: :read, get_by: [:id])
      define(:submit_ticket, action: :create, args: [:subject, :body])
      define(:close_ticket, action: :close)
      define(:stream_tickets, action: :read)
    end
  end
end
