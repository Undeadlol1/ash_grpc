defmodule AshGrpc.DomainTest do
  use ExUnit.Case, async: true

  import AshGrpc.TestHelpers, only: [method_named: 2]

  alias AshGrpc.Domain.Info
  alias AshGrpc.Examples.SupportDesk
  alias AshGrpc.Examples.SupportTicket
  alias AshGrpc.Support.V1.CloseTicketRequestMapper
  alias AshGrpc.Support.V1.ListTicketsRequestMapper
  alias AshGrpc.Support.V1.ResponseMapper
  alias AshGrpc.Support.V1.SubmitTicketBatchResponseMapper
  alias AshGrpc.Support.V1.SubmitTicketStreamRequestMapper
  alias AshGrpc.TestRunner

  describe "GIVEN the grpc domain" do
    test "WHEN the support desk routes are read THEN each route names its resource, action, mappers and method kind" do
      [service] = Info.routes(SupportDesk)
      submit_ticket_route = method_named(service.routes, :submit_ticket)
      close_ticket_route = method_named(service.routes, :close_ticket)
      stream_tickets_route = method_named(service.routes, :stream_tickets)
      submit_ticket_batch_route = method_named(service.routes, :submit_ticket_batch)
      sync_tickets_route = method_named(service.routes, :sync_tickets)

      assert service.path == "/support"

      assert submit_ticket_route.name == :submit_ticket
      assert submit_ticket_route.resource == SupportTicket
      assert submit_ticket_route.action == :create
      assert Map.fetch!(submit_ticket_route, :method_kind) == :unary
      assert Map.get(submit_ticket_route, :request_mapper) == nil
      assert Map.fetch!(submit_ticket_route, :response_mapper) == ResponseMapper

      assert close_ticket_route.name == :close_ticket
      assert close_ticket_route.resource == SupportTicket
      assert close_ticket_route.action == :close
      assert Map.fetch!(close_ticket_route, :method_kind) == :unary
      assert Map.fetch!(close_ticket_route, :request_mapper) == CloseTicketRequestMapper
      assert Map.fetch!(close_ticket_route, :response_mapper) == ResponseMapper

      assert stream_tickets_route.name == :stream_tickets
      assert stream_tickets_route.resource == SupportTicket
      assert stream_tickets_route.action == :read
      assert Map.fetch!(stream_tickets_route, :method_kind) == :server_stream
      assert Map.fetch!(stream_tickets_route, :request_mapper) == ListTicketsRequestMapper
      assert Map.fetch!(stream_tickets_route, :response_mapper) == ResponseMapper
      assert Map.fetch!(stream_tickets_route, :deprecated) == "use list_tickets_v2"

      assert submit_ticket_batch_route.name == :submit_ticket_batch
      assert submit_ticket_batch_route.resource == SupportTicket
      assert submit_ticket_batch_route.action == :create
      assert Map.fetch!(submit_ticket_batch_route, :method_kind) == :client_stream

      assert Map.fetch!(submit_ticket_batch_route, :request_mapper) ==
               SubmitTicketStreamRequestMapper

      assert Map.fetch!(submit_ticket_batch_route, :response_mapper) ==
               SubmitTicketBatchResponseMapper

      assert sync_tickets_route.name == :sync_tickets
      assert sync_tickets_route.resource == SupportTicket
      assert sync_tickets_route.action == :create
      assert Map.fetch!(sync_tickets_route, :method_kind) == :bidirectional_stream
      assert Map.fetch!(sync_tickets_route, :request_mapper) == SubmitTicketStreamRequestMapper
      assert Map.fetch!(sync_tickets_route, :response_mapper) == ResponseMapper
    end

    test "WHEN a unary binding is built from route metadata THEN it has the resource, action, mappers and error mapper" do
      assert %AshGrpc.Method{
               resource: SupportTicket,
               action: :create,
               request_mapper: AshGrpc.InferredRequestMapper,
               response_mapper: ResponseMapper,
               runner: TestRunner,
               error_mapper: AshGrpc.ErrorMapper
             } = Info.unary_binding(SupportDesk, :submit_ticket, runner: TestRunner)
    end

    test "WHEN a server stream binding is built from route metadata THEN it keeps its deprecation and stream kind" do
      assert %AshGrpc.Method{
               resource: SupportTicket,
               action: :read,
               request_mapper: ListTicketsRequestMapper,
               response_mapper: ResponseMapper,
               runner: TestRunner,
               error_mapper: AshGrpc.ErrorMapper,
               kind: :server_stream,
               deprecated: "use list_tickets_v2"
             } = Info.binding(SupportDesk, :stream_tickets, runner: TestRunner)
    end

    test "WHEN a client stream binding is built from route metadata THEN it has the client stream kind" do
      assert %AshGrpc.Method{
               resource: SupportTicket,
               action: :create,
               request_mapper: SubmitTicketStreamRequestMapper,
               response_mapper: SubmitTicketBatchResponseMapper,
               runner: TestRunner,
               error_mapper: AshGrpc.ErrorMapper,
               kind: :client_stream
             } = Info.binding(SupportDesk, :submit_ticket_batch, runner: TestRunner)
    end

    test "WHEN a bidirectional stream binding is built from route metadata THEN it has the bidirectional stream kind" do
      assert %AshGrpc.Method{
               resource: SupportTicket,
               action: :create,
               request_mapper: SubmitTicketStreamRequestMapper,
               response_mapper: ResponseMapper,
               runner: TestRunner,
               error_mapper: AshGrpc.ErrorMapper,
               kind: :bidirectional_stream
             } = Info.binding(SupportDesk, :sync_tickets, runner: TestRunner)
    end

    test "WHEN a ticket is submitted through the domain interface THEN the subject and body are kept" do
      assert {:ok, ticket} = SupportDesk.submit_ticket("printer broken", "paper jam")
      assert ticket.subject == "printer broken"
      assert ticket.body == "paper jam"
    end

    test "WHEN a ticket is closed through the domain interface THEN its status is closed" do
      assert {:ok, ticket} = SupportDesk.submit_ticket("printer broken", "paper jam")
      assert {:ok, closed_ticket} = SupportDesk.close_ticket(ticket)
      assert closed_ticket.status == :closed
    end
  end
end
