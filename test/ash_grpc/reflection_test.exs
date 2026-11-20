defmodule AshGrpc.ReflectionTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestHelpers, only: [method_named: 2]

  alias AshGrpc.Examples.SupportDesk
  alias AshGrpc.Examples.SupportTicket
  alias AshGrpc.Reflection
  alias AshGrpc.Router
  alias AshGrpc.Support.V1.ListTicketsRequest
  alias AshGrpc.Support.V1.SubmitTicketReply
  alias AshGrpc.Support.V1.SubmitTicketRequest
  alias AshGrpc.Support.V1.Tickets.Server
  alias AshGrpc.Support.V1.Tickets.Service
  alias Google.Protobuf.FileDescriptorProto
  alias Google.Protobuf.FileDescriptorSet

  setup_all do
    {:ok, port, supervisor} = AshGrpc.TestSupport.start_server_on_free_port()
    {:ok, channel} = AshGrpc.TestSupport.connect_channel(port)

    on_exit(fn ->
      AshGrpc.TestSupport.stop_server(supervisor)
    end)

    {:ok, channel: channel}
  end

  describe "GIVEN the grpc reflection" do
    test "WHEN the domain is described THEN the grpc surface carries protobuf request and response metadata" do
      assert [service] = Reflection.describe_domain(SupportDesk, service: Service)

      assert service.path == "/support"
      assert service.service == Service
      assert service.service_name == "ash_grpc.support.v1.Tickets"

      assert %{name: :submit_ticket} =
               submit_ticket = method_named(service.methods, :submit_ticket)

      assert submit_ticket.rpc_name == :SubmitTicket
      assert submit_ticket.grpc_path == "/ash_grpc.support.v1.Tickets/SubmitTicket"
      assert submit_ticket.kind == :unary
      assert submit_ticket.resource == SupportTicket
      assert submit_ticket.action == :create
      assert submit_ticket.deprecated == nil
      assert submit_ticket.request.module == SubmitTicketRequest
      assert submit_ticket.request.stream? == false

      assert Enum.map(submit_ticket.request.fields, &{&1.number, &1.name, &1.type}) == [
               {1, :subject, :string},
               {2, :body, :string}
             ]

      assert submit_ticket.response.module == SubmitTicketReply
      assert submit_ticket.response.stream? == false

      assert Enum.map(submit_ticket.response.fields, &{&1.number, &1.name, &1.type}) == [
               {1, :ticket_id, :string},
               {2, :status, :string}
             ]

      assert %{name: :stream_tickets} =
               stream_tickets = method_named(service.methods, :stream_tickets)

      assert stream_tickets.rpc_name == :StreamTickets
      assert stream_tickets.kind == :server_stream
      assert stream_tickets.deprecated == "use list_tickets_v2"
      assert stream_tickets.request.module == ListTicketsRequest
      assert stream_tickets.request.stream? == false
      assert stream_tickets.response.module == SubmitTicketReply
      assert stream_tickets.response.stream? == true

      assert %{name: :submit_ticket_batch} =
               submit_ticket_batch =
               method_named(service.methods, :submit_ticket_batch)

      assert submit_ticket_batch.rpc_name == :SubmitTicketBatch
      assert submit_ticket_batch.kind == :client_stream
      assert submit_ticket_batch.request.stream? == true
      assert submit_ticket_batch.response.stream? == false

      assert %{name: :sync_tickets} = sync_tickets = method_named(service.methods, :sync_tickets)
      assert sync_tickets.rpc_name == :SyncTickets
      assert sync_tickets.kind == :bidirectional_stream
      assert sync_tickets.request.stream? == true
      assert sync_tickets.response.stream? == true
    end

    test "WHEN the registered grpc servers are described THEN their services and methods are listed" do
      services = Reflection.describe_endpoint(Router)

      assert Enum.any?(services, &(&1.service == Grpc.Reflection.V1.ServerReflection.Service))

      assert service = Enum.find(services, &(&1.service == Service))

      assert service.server == Server
      assert service.service == Service
      assert service.service_name == "ash_grpc.support.v1.Tickets"

      assert Enum.map(service.methods, &{&1.rpc_name, &1.kind}) == [
               {:SubmitTicket, :unary},
               {:CloseTicket, :unary},
               {:StreamTickets, :server_stream},
               {:SubmitTicketBatch, :client_stream},
               {:SyncTickets, :bidirectional_stream}
             ]
    end

    test "WHEN the descriptor set is exported THEN it holds a protobuf file descriptor for the declared service" do
      descriptor_set = Reflection.descriptor_set(SupportDesk, service: Service)

      assert %FileDescriptorSet{file: [file_descriptor]} = descriptor_set
      assert file_descriptor.name == "ash_grpc/support/v1/tickets.proto"
      assert file_descriptor.package == "ash_grpc.support.v1"
      assert file_descriptor.syntax == "proto3"

      assert [service_descriptor] = file_descriptor.service
      assert service_descriptor.name == "Tickets"

      assert [submit_ticket_method | _] = service_descriptor.method
      assert submit_ticket_method.name == "SubmitTicket"
      assert submit_ticket_method.input_type == ".ash_grpc.support.v1.SubmitTicketRequest"
      assert submit_ticket_method.output_type == ".ash_grpc.support.v1.SubmitTicketReply"
      assert submit_ticket_method.client_streaming == false
      assert submit_ticket_method.server_streaming == false

      assert stream_tickets_method =
               Enum.find(service_descriptor.method, &(&1.name == "StreamTickets"))

      assert stream_tickets_method.server_streaming == true
      assert stream_tickets_method.options.deprecated == true

      assert submit_ticket_message =
               Enum.find(file_descriptor.message_type, &(&1.name == "SubmitTicketRequest"))

      assert Enum.map(submit_ticket_message.field, &{&1.number, &1.name, &1.type}) == [
               {1, "subject", :TYPE_STRING},
               {2, "body", :TYPE_STRING}
             ]

      encoded_descriptor_set = FileDescriptorSet.encode(descriptor_set)

      assert FileDescriptorSet.decode(encoded_descriptor_set) == descriptor_set
    end

    test "WHEN the running server is queried through reflection THEN the ticket service symbol resolves to its file",
         %{
           channel: channel
         } do
      assert {:ok, service_names} = Reflection.list_services(channel)
      assert "ash_grpc.support.v1.Tickets" in service_names

      assert {:ok, %FileDescriptorProto{} = file_descriptor} =
               Reflection.file_containing_symbol(channel, "ash_grpc.support.v1.Tickets")

      assert file_descriptor.package == "ash_grpc.support.v1"
      assert Enum.map(file_descriptor.service, & &1.name) == ["Tickets"]
    end
  end
end
