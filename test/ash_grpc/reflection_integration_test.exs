defmodule AshGrpc.ReflectionIntegrationTest do
  use ExUnit.Case, async: false

  alias AshGrpc.Reflection

  @moduletag :integration

  setup_all do
    {:ok, port, supervisor} = AshGrpc.TestSupport.start_server_on_free_port()
    {:ok, channel} = AshGrpc.TestSupport.connect_channel(port)

    on_exit(fn ->
      AshGrpc.TestSupport.stop_server(supervisor)
    end)

    {:ok, channel: channel}
  end

  describe "GIVEN the grpc reflection service" do
    test "WHEN the running server is queried through reflection THEN the ticketing service lists its five methods",
         %{
           channel: channel
         } do
      assert {:ok, service_names} = Reflection.list_services(channel)
      assert "ash_grpc.support.v1.Tickets" in service_names

      assert {:ok, file_descriptor} =
               Reflection.file_containing_symbol(channel, "ash_grpc.support.v1.Tickets")

      assert file_descriptor.package == "ash_grpc.support.v1"

      assert [service_descriptor] = file_descriptor.service
      assert service_descriptor.name == "Tickets"

      assert Enum.map(service_descriptor.method, & &1.name) == [
               "SubmitTicket",
               "CloseTicket",
               "StreamTickets",
               "SubmitTicketBatch",
               "SyncTickets"
             ]
    end
  end
end
