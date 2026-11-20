defmodule AshGrpc.TransportTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestHelpers, only: [maybe_sort_subjects: 2, unique_integer: 0]

  alias AshGrpc.Examples.SupportDesk
  alias AshGrpc.Examples.SupportTicket
  alias AshGrpc.Support.V1.CloseTicketRequest
  alias AshGrpc.Support.V1.ListTicketsRequest
  alias AshGrpc.Support.V1.RequestMapper
  alias AshGrpc.Support.V1.ResponseMapper
  alias AshGrpc.Support.V1.SubmitTicketBatchReply
  alias AshGrpc.Support.V1.SubmitTicketReply
  alias AshGrpc.Support.V1.SubmitTicketRequest
  alias AshGrpc.Support.V1.Tickets.Stub
  alias AshGrpc.Support.V1.TransportOptions.EchoOptionsReply
  alias AshGrpc.Support.V1.TransportOptions.EchoOptionsRequest
  alias AshGrpc.Support.V1.TransportOptions.Stub, as: TransportOptionsStub

  setup_all do
    {:ok, port, supervisor} = AshGrpc.TestSupport.start_server_on_free_port()
    {:ok, channel} = AshGrpc.TestSupport.connect_channel(port)

    on_exit(fn ->
      AshGrpc.TestSupport.stop_server(supervisor)
    end)

    {:ok, channel: channel}
  end

  describe "GIVEN the grpc transport WHEN tickets are translated between protobuf and ash" do
    test "THEN a submit ticket payload is translated to ash input" do
      assert {:ok, ["printer broken", "paper jam"]} =
               RequestMapper.to_ash_input(submit_ticket_request())
    end

    test "THEN an incomplete submit ticket payload is rejected" do
      assert {:error, %{code: :invalid_argument, message: "subject and body are required"}} =
               RequestMapper.to_ash_input(%SubmitTicketRequest{subject: "", body: ""})
    end

    test "THEN support tickets are translated into protobuf replies" do
      assert {:ok, %SubmitTicketReply{ticket_id: "ticket-id", status: "closed"}} =
               ResponseMapper.to_response(closed_support_ticket())
    end
  end

  describe "GIVEN the grpc transport" do
    test "WHEN unary requests are dispatched through the route bindings THEN a submitted ticket is then closed" do
      assert {:ok, %SubmitTicketReply{status: "submitted", ticket_id: ticket_id}} =
               AshGrpc.Transport.handle_unary(
                 SupportDesk,
                 :submit_ticket,
                 submit_ticket_request()
               )

      assert {:ok, %SubmitTicketReply{status: "closed", ticket_id: ^ticket_id}} =
               AshGrpc.Transport.handle_unary(
                 SupportDesk,
                 :close_ticket,
                 %CloseTicketRequest{ticket_id: ticket_id}
               )
    end

    test "WHEN a unary submit is handled THEN the created ticket is persisted as open" do
      unique_suffix = unique_integer()

      assert {:ok, %SubmitTicketReply{status: "submitted", ticket_id: ticket_id}} =
               AshGrpc.Transport.handle_unary(
                 SupportDesk,
                 :submit_ticket,
                 ticket_request("printer broken", "paper jam", unique_suffix)
               )

      assert {:ok, ticket} = SupportDesk.get_ticket(ticket_id)
      assert ticket.subject == "printer broken #{unique_suffix}"
      assert ticket.body == "paper jam #{unique_suffix}"
      assert ticket.status == :open
    end

    test "WHEN a unary close is handled THEN the closed status is persisted" do
      unique_suffix = unique_integer()

      assert {:ok, ticket} =
               SupportDesk.submit_ticket(
                 "printer broken #{unique_suffix}",
                 "paper jam #{unique_suffix}"
               )

      ticket_id = ticket.id

      assert {:ok, %SubmitTicketReply{status: "closed", ticket_id: ^ticket_id}} =
               AshGrpc.Transport.handle_unary(
                 SupportDesk,
                 :close_ticket,
                 %CloseTicketRequest{ticket_id: ticket.id}
               )

      assert {:ok, closed_ticket} = SupportDesk.get_ticket(ticket_id)
      assert closed_ticket.status == :closed
    end

    test "WHEN a unary call carries actor, tenant and context options THEN the Ash execution options reach the handler" do
      actor = %{id: "grpc-user"}
      context = %{locale: "en", request_id: "grpc-request-1"}

      assert {:ok,
              %{
                request: %{payload: "hello"},
                opts: opts
              }} =
               AshGrpc.Transport.handle_unary(
                 AshGrpc.TransportOptionsDomain,
                 :echo_options,
                 %{payload: "hello"},
                 actor: actor,
                 authorize?: true,
                 tenant: "tenant-1",
                 context: context
               )

      assert Keyword.get(opts, :actor) == actor
      assert Keyword.get(opts, :authorize?) == true
      assert Keyword.get(opts, :tenant) == "tenant-1"
      assert Keyword.get(opts, :context) == context
    end

    test "WHEN a live unary call sends reserved grpc metadata THEN it becomes Ash execution options",
         %{
           channel: channel
         } do
      metadata = %{
        "x-ash-actor" => Jason.encode!(%{"id" => "grpc-user"}),
        "x-ash-authorize" => "true",
        "x-ash-context" => Jason.encode!(%{"locale" => "en", "request_id" => "grpc-request-1"}),
        "x-ash-tenant" => "tenant-1"
      }

      assert {:ok,
              %EchoOptionsReply{
                actor_id: "grpc-user",
                authorize: true,
                context_locale: "en",
                context_request_id: "grpc-request-1",
                payload: "hello",
                tenant: "tenant-1"
              }} =
               TransportOptionsStub.echo_options(
                 channel,
                 %EchoOptionsRequest{payload: "hello"},
                 metadata: metadata
               )
    end

    test "WHEN a live unary call sends reserved metadata to an endpoint that does not trust it THEN the call is rejected as permission denied",
         %{channel: channel} do
      metadata = %{"x-ash-authorize" => "false"}

      assert {:error, %GRPC.RPCError{status: 7, message: message}} =
               Stub.submit_ticket(
                 channel,
                 %SubmitTicketRequest{subject: "s", body: "b"},
                 metadata: metadata
               )

      assert message =~ "not trusted"
    end

    test "WHEN a live unary call sends an invalid reserved metadata value THEN the call is rejected as invalid argument",
         %{channel: channel} do
      metadata = %{"x-ash-authorize" => "sometimes"}

      assert {:error, %GRPC.RPCError{status: 3, message: message}} =
               TransportOptionsStub.echo_options(
                 channel,
                 %EchoOptionsRequest{payload: "hello"},
                 metadata: metadata
               )

      assert message =~ "x-ash-authorize must be true or false"
    end

    test "WHEN actor metadata is resolved THEN it becomes an Ash actor" do
      assert {:ok, %{id: "grpc-user"}} =
               AshGrpc.Support.V1.TransportOptions.ActorResolver.resolve(%{"id" => "grpc-user"})
    end

    test "WHEN a server stream is routed through the unary transport THEN an internal error names the expected transport" do
      assert {:error, %{code: :internal, message: message}} =
               AshGrpc.Transport.handle_unary(SupportDesk, :stream_tickets, %ListTicketsRequest{})

      assert message =~ "route :stream_tickets expects :server_stream transport"
      assert message =~ "got :unary"
    end

    test "WHEN a unary method is routed through the client stream transport THEN an internal error names the expected transport" do
      assert {:error, %{code: :internal, message: message}} =
               AshGrpc.Transport.handle_client_stream(
                 SupportDesk,
                 :submit_ticket,
                 Stream.map([submit_ticket_request()], & &1)
               )

      assert message =~ "route :submit_ticket expects :unary transport"
      assert message =~ "got :client_stream"
    end

    test "WHEN a bidirectional stream method is routed through the client stream transport THEN an internal error names the expected transport" do
      assert {:error, %{code: :internal, message: message}} =
               AshGrpc.Transport.handle_client_stream(
                 SupportDesk,
                 :sync_tickets,
                 Stream.map([submit_ticket_request()], & &1)
               )

      assert message =~ "route :sync_tickets expects :bidirectional_stream transport"
      assert message =~ "got :client_stream"
    end

    test "WHEN a response is unwrapped THEN an ok response is returned and a failure raises a mapped error" do
      assert :the_response == AshGrpc.Transport.unwrap_response({:ok, :the_response})

      assert_raise GRPC.RPCError, fn ->
        AshGrpc.Transport.unwrap_response({:error, %{code: :not_found, message: "gone"}})
      end
    end

    test "WHEN the route name is unknown THEN a clear argument error is raised" do
      assert_raise ArgumentError, ~r/unknown ash_grpc route: :missing_route/, fn ->
        AshGrpc.Transport.handle_unary(SupportDesk, :missing_route, submit_ticket_request())
      end
    end

    test "WHEN the transport module is loaded THEN the streaming entrypoints are exported" do
      assert function_exported?(AshGrpc.Transport, :handle_server_stream, 4)
      assert function_exported?(AshGrpc.Transport, :handle_client_stream, 3)
      assert function_exported?(AshGrpc.Transport, :handle_bidirectional_stream, 4)
    end

    test "WHEN a client stream batch is handled without a grpc server THEN both tickets are submitted and persisted" do
      unique_suffix = unique_integer()

      assert {:ok, %SubmitTicketBatchReply{submitted_count: 2}} =
               AshGrpc.Transport.handle_client_stream(
                 SupportDesk,
                 :submit_ticket_batch,
                 Stream.map(
                   [
                     ticket_request("printer broken", "paper jam", unique_suffix),
                     ticket_request("scanner jam", "toner spill", unique_suffix)
                   ],
                   & &1
                 )
               )

      assert persisted_subjects_with_suffix(unique_suffix) ==
               Enum.sort([
                 "printer broken #{unique_suffix}",
                 "scanner jam #{unique_suffix}"
               ])
    end

    test "WHEN a client stub submits a ticket over grpc THEN it is submitted and can then be closed",
         %{channel: channel} do
      assert {:ok, %SubmitTicketReply{status: "submitted", ticket_id: ticket_id}} =
               Stub.submit_ticket(channel, submit_ticket_request())

      assert {:ok, %SubmitTicketReply{status: "closed", ticket_id: ^ticket_id}} =
               Stub.close_ticket(channel, %CloseTicketRequest{ticket_id: ticket_id})

      assert is_binary(ticket_id)
    end

    test "WHEN a ticket is closed before a server stream is read THEN the stream reports it as closed",
         %{channel: channel} do
      unique_suffix = unique_integer()

      assert {:ok, ticket} =
               SupportDesk.submit_ticket(
                 "printer broken #{unique_suffix}",
                 "paper jam #{unique_suffix}"
               )

      assert {:ok, _closed_ticket} = SupportDesk.close_ticket(ticket)
      assert {:ok, replies} = Stub.stream_tickets(channel, %ListTicketsRequest{})

      assert Enum.any?(replies, fn
               {:ok, %SubmitTicketReply{ticket_id: reply_ticket_id, status: "closed"}}
               when reply_ticket_id == ticket.id ->
                 true

               _other ->
                 false
             end)
    end

    test "WHEN a client stub streams tickets over grpc THEN both submitted tickets appear in the stream",
         %{channel: channel} do
      unique_suffix = unique_integer()

      assert {:ok, %SubmitTicketReply{ticket_id: first_ticket_id}} =
               Stub.submit_ticket(
                 channel,
                 %SubmitTicketRequest{
                   subject: "printer broken #{unique_suffix}",
                   body: "paper jam #{unique_suffix}"
                 }
               )

      assert {:ok, %SubmitTicketReply{ticket_id: second_ticket_id}} =
               Stub.submit_ticket(
                 channel,
                 %SubmitTicketRequest{
                   subject: "scanner jam #{unique_suffix}",
                   body: "toner spill #{unique_suffix}"
                 }
               )

      assert {:ok, replies} = Stub.stream_tickets(channel, %ListTicketsRequest{})

      streamed_ticket_ids =
        Enum.map(replies, fn {:ok, %SubmitTicketReply{ticket_id: ticket_id}} -> ticket_id end)

      assert first_ticket_id in streamed_ticket_ids
      assert second_ticket_id in streamed_ticket_ids
    end

    test "WHEN a client stub submits several tickets through client streaming THEN both are persisted and counted",
         %{
           channel: channel
         } do
      unique_suffix = unique_integer()

      stream =
        channel
        |> Stub.submit_ticket_batch()
        |> send_batch_ticket_requests(unique_suffix)

      assert {:ok, %SubmitTicketBatchReply{submitted_count: 2}} = GRPC.Stub.recv(stream)

      assert persisted_subjects_with_suffix(unique_suffix) ==
               Enum.sort([
                 "printer broken #{unique_suffix}",
                 "scanner jam #{unique_suffix}"
               ])
    end

    test "WHEN a client stream sends an invalid ticket THEN the call is rejected as invalid argument",
         %{
           channel: channel
         } do
      stream =
        channel
        |> Stub.submit_ticket_batch()
        |> GRPC.Stub.send_request(%SubmitTicketRequest{subject: "", body: "paper jam"},
          end_stream: true
        )

      assert {:error, %GRPC.RPCError{status: 3, message: message}} = GRPC.Stub.recv(stream)
      assert message =~ "subject and body are required"
    end

    test "WHEN a bidirectional stream sends an invalid ticket THEN the call is rejected as invalid argument",
         %{
           channel: channel
         } do
      stream =
        channel
        |> Stub.sync_tickets()
        |> GRPC.Stub.send_request(%SubmitTicketRequest{subject: "", body: "paper jam"},
          end_stream: true
        )

      assert {:error, %GRPC.RPCError{status: 3, message: message}} = GRPC.Stub.recv(stream)
      assert message =~ "subject and body are required"
    end

    test "WHEN a bidirectional stream sends an invalid item after a valid one THEN replies keep their order until the invalid item",
         %{
           channel: channel
         } do
      unique_suffix = unique_integer()

      stream =
        channel
        |> Stub.sync_tickets()
        |> GRPC.Stub.send_request(ticket_request("printer broken", "paper jam", unique_suffix))
        |> GRPC.Stub.send_request(%SubmitTicketRequest{subject: "", body: "paper jam"})
        |> GRPC.Stub.send_request(
          ticket_request("scanner jam", "toner spill", unique_suffix),
          end_stream: true
        )

      assert {:ok, replies} = GRPC.Stub.recv(stream)

      assert [
               {:ok, %SubmitTicketReply{status: "submitted", ticket_id: first_ticket_id}},
               {:error, %GRPC.RPCError{status: 3, message: message}}
             ] = Enum.to_list(replies)

      assert message =~ "subject and body are required"

      assert {:ok, first_ticket} = SupportDesk.get_ticket(first_ticket_id)
      assert first_ticket.subject == "printer broken #{unique_suffix}"

      assert persisted_subjects_with_suffix(unique_suffix, sort?: false) == [
               "printer broken #{unique_suffix}"
             ]
    end

    test "WHEN a client stub exchanges tickets through bidirectional streaming THEN both tickets are replied to and persisted",
         %{
           channel: channel
         } do
      unique_suffix = unique_integer()

      stream =
        channel
        |> Stub.sync_tickets()
        |> send_batch_ticket_requests(unique_suffix)

      assert {:ok, replies} = GRPC.Stub.recv(stream)

      streamed_replies = Enum.to_list(replies)

      assert length(streamed_replies) == 2

      assert Enum.all?(streamed_replies, fn
               {:ok, %SubmitTicketReply{status: "submitted", ticket_id: ticket_id}}
               when is_binary(ticket_id) ->
                 true

               _other ->
                 false
             end)

      persisted_subjects =
        streamed_replies
        |> Enum.map(fn {:ok, %SubmitTicketReply{ticket_id: ticket_id}} -> ticket_id end)
        |> Enum.map(fn ticket_id ->
          {:ok, ticket} = SupportDesk.get_ticket(ticket_id)
          ticket.subject
        end)
        |> Enum.sort()

      assert persisted_subjects ==
               Enum.sort([
                 "printer broken #{unique_suffix}",
                 "scanner jam #{unique_suffix}"
               ])
    end
  end

  defp submit_ticket_request do
    %SubmitTicketRequest{subject: "printer broken", body: "paper jam"}
  end

  defp send_batch_ticket_requests(stream, unique_suffix) do
    stream
    |> GRPC.Stub.send_request(ticket_request("printer broken", "paper jam", unique_suffix))
    |> GRPC.Stub.send_request(
      ticket_request("scanner jam", "toner spill", unique_suffix),
      end_stream: true
    )
  end

  defp ticket_request(subject, body, unique_suffix) do
    %SubmitTicketRequest{
      subject: "#{subject} #{unique_suffix}",
      body: "#{body} #{unique_suffix}"
    }
  end

  defp persisted_subjects_with_suffix(unique_suffix, options \\ []) do
    assert {:ok, tickets} = SupportDesk.stream_tickets()

    tickets
    |> Enum.map(& &1.subject)
    |> Enum.filter(&String.ends_with?(&1, " #{unique_suffix}"))
    |> maybe_sort_subjects(options)
  end

  defp closed_support_ticket do
    %SupportTicket{id: "ticket-id", status: :closed}
  end
end

defmodule AshGrpc.TransportOptionsDomain do
  @moduledoc false

  use Ash.Domain,
    validate_config_inclusion?: false,
    extensions: [AshGrpc.Domain]

  alias AshGrpc.Examples.SupportTicket

  grpc do
    routes do
      service "/transport_options" do
        unary(:echo_options, SupportTicket, :create,
          handler: AshGrpc.TransportOptionsHandler,
          request_mapper: AshGrpc.TransportOptionsRequestMapper,
          response_mapper: AshGrpc.TransportOptionsResponseMapper
        )
      end
    end
  end

  resources do
    resource(SupportTicket)
  end
end

defmodule AshGrpc.TransportOptionsHandler do
  @moduledoc false

  def echo_options(request, opts \\ []) do
    {:ok, %{request: request, opts: opts}}
  end
end

defmodule AshGrpc.TransportOptionsRequestMapper do
  @moduledoc false

  def to_ash_input(%{payload: _payload} = request), do: {:ok, request}
end

defmodule AshGrpc.TransportOptionsResponseMapper do
  @moduledoc false

  def to_response(response), do: {:ok, response}
end
