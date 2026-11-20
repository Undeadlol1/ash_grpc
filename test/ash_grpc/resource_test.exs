defmodule AshGrpc.ResourceTest do
  use ExUnit.Case, async: true

  alias AshGrpc.Examples.SupportTicket

  describe "GIVEN the support ticket resource" do
    test "WHEN a ticket is created THEN the submitted fields are persisted as open" do
      assert {:ok, ticket} =
               Ash.create(SupportTicket, %{subject: "printer broken", body: "paper jam"})

      assert ticket.subject == "printer broken"
      assert ticket.body == "paper jam"
      assert ticket.status == :open
      assert is_binary(ticket.id)
    end

    test "WHEN a ticket is closed THEN it is marked closed" do
      assert {:ok, ticket} =
               Ash.create(SupportTicket, %{subject: "printer broken", body: "paper jam"})

      assert {:ok, closed_ticket} = AshGrpc.Examples.SupportDesk.close_ticket(ticket)
      assert closed_ticket.status == :closed
    end

    test "WHEN a ticket is read by id THEN the submitted ticket is fetched" do
      assert {:ok, ticket} =
               Ash.create(SupportTicket, %{subject: "printer broken", body: "paper jam"})

      assert reloaded_ticket = Ash.get!(SupportTicket, ticket.id)
      assert reloaded_ticket.id == ticket.id
      assert reloaded_ticket.status == :open
    end
  end
end
