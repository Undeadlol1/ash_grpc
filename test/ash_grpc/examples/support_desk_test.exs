defmodule AshGrpc.Examples.SupportDeskTest do
  use ExUnit.Case, async: true

  alias AshGrpc.Domain.Info
  alias AshGrpc.Examples.SupportDesk

  describe "GIVEN the support desk example" do
    test "WHEN the support example routes are read THEN every grpc method kind is declared" do
      routes =
        SupportDesk
        |> Info.routes()
        |> Enum.flat_map(& &1.routes)

      assert route_kind(routes, :submit_ticket) == :unary
      assert route_kind(routes, :close_ticket) == :unary
      assert route_kind(routes, :stream_tickets) == :server_stream
      assert route_kind(routes, :submit_ticket_batch) == :client_stream
      assert route_kind(routes, :sync_tickets) == :bidirectional_stream
    end
  end

  defp route_kind(routes, route_name) do
    routes
    |> Enum.find(&(&1.name == route_name))
    |> Map.fetch!(:method_kind)
  end
end
