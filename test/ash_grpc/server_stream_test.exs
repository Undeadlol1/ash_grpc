defmodule AshGrpc.ServerStreamTest do
  use ExUnit.Case, async: true

  alias AshGrpc.Domain.Info
  alias AshGrpc.Examples.SupportTicket
  alias AshGrpc.Method
  alias AshGrpc.TestRunner
  alias AshGrpc.TestSupport.ServerStreamRequestMapper
  alias AshGrpc.TestSupport.ServerStreamResponseMapper

  defmodule StreamingSupportDesk do
    @moduledoc false

    use Ash.Domain,
      validate_config_inclusion?: false,
      extensions: [AshGrpc.Domain]

    grpc do
      routes do
        service "/support" do
          server_stream(:stream_tickets, SupportTicket, :read,
            request_mapper: ServerStreamRequestMapper,
            response_mapper: ServerStreamResponseMapper,
            deprecated: "use list_tickets_v2"
          )
        end
      end
    end

    resources do
      resource SupportTicket do
        define(:stream_tickets, action: :read)
      end
    end
  end

  describe "GIVEN the server stream" do
    test "WHEN the stream route is declared THEN its kind is server stream and its deprecation is kept" do
      [service] = Info.routes(StreamingSupportDesk)
      [route] = service.routes

      assert service.path == "/support"
      assert route.name == :stream_tickets
      assert Map.fetch!(route, :method_kind) == :server_stream
      assert Map.fetch!(route, :deprecated) == "use list_tickets_v2"
    end

    test "WHEN the stream route is bound THEN the binding keeps its resource, action, mappers and kind" do
      assert %Method{
               name: :stream_tickets,
               resource: SupportTicket,
               action: :read,
               request_mapper: ServerStreamRequestMapper,
               response_mapper: ServerStreamResponseMapper,
               runner: TestRunner,
               error_mapper: AshGrpc.ErrorMapper,
               kind: :server_stream,
               deprecated: "use list_tickets_v2"
             } = Info.binding(StreamingSupportDesk, :stream_tickets, runner: TestRunner)
    end

    test "WHEN the runtime is loaded THEN the server stream entrypoint is exported" do
      assert function_exported?(AshGrpc.ServerStream, :call, 3)
    end
  end

  describe "GIVEN the server stream WHEN a deadline is enforced" do
    test "THEN a finite deadline is derived from a propagated Ash timeout" do
      binding = %Method{resource: SupportTicket, action: :read, action_options: [timeout: 200]}

      assert AshGrpc.ServerStream.deadline_from(binding, 1_000) == 1_200
    end

    test "THEN there is no deadline when no timeout was propagated" do
      binding = %Method{resource: SupportTicket, action: :read, action_options: []}

      assert AshGrpc.ServerStream.deadline_from(binding, 1_000) == :infinity
    end

    test "THEN the deadline is reported as exceeded once now reaches it" do
      refute AshGrpc.ServerStream.exceeded?(:infinity, 5_000)
      refute AshGrpc.ServerStream.exceeded?(1_200, 1_199)
      assert AshGrpc.ServerStream.exceeded?(1_200, 1_200)
      assert AshGrpc.ServerStream.exceeded?(1_200, 5_000)
    end
  end
end
