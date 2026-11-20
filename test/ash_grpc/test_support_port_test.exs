defmodule AshGrpc.TestSupportPortTest do
  use ExUnit.Case, async: false

  alias AshGrpc.TestSupport

  describe "GIVEN the test support port" do
    test "WHEN a server starts on a free port THEN it is reachable and reports the port it bound" do
      {:ok, port, supervisor} = TestSupport.start_server_on_free_port()

      on_exit(fn -> TestSupport.stop_server(supervisor) end)

      assert is_integer(port) and port > 0
      assert {:ok, channel} = TestSupport.connect_channel(port)

      GRPC.Stub.disconnect(channel)
    end

    test "WHEN the first candidate port is already taken THEN another port is picked" do
      {:ok, taken_port} = TestSupport.find_free_port()

      {:ok, squatter} =
        :gen_tcp.listen(taken_port, [:binary, active: false, ip: {127, 0, 0, 1}])

      on_exit(fn -> :gen_tcp.close(squatter) end)

      {:ok, port, supervisor} =
        TestSupport.start_server_on_free_port(port_source: fn -> taken_port end)

      on_exit(fn -> TestSupport.stop_server(supervisor) end)

      assert port != taken_port
    end
  end
end
