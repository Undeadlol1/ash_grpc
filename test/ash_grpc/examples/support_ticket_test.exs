defmodule AshGrpc.Examples.SupportTicketTest do
  use ExUnit.Case, async: true

  alias AshGrpc.Examples.SupportDesk
  alias AshGrpc.Examples.SupportTicket

  describe "GIVEN the support ticket example" do
    test "WHEN a ticket is created THEN the subject, body and open status are kept" do
      assert {:ok, ticket} = SupportDesk.submit_ticket("Need help", "The app crashed")

      assert ticket.subject == "Need help"
      assert ticket.body == "The app crashed"
      assert ticket.status == :open
    end

    test "WHEN tickets are read after one is submitted THEN the submitted ticket is among them" do
      {:ok, ticket} = SupportDesk.submit_ticket("Read me", "Please list this ticket")

      assert {:ok, tickets} = Ash.read(SupportTicket)
      assert Enum.any?(tickets, &(&1.id == ticket.id))
    end
  end

  describe "GIVEN the support ticket example WHEN a field is checked against its length limit" do
    defp submit_ticket_with(attrs) do
      SupportTicket
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(%{subject: "Need help", body: "The app crashed"}, attrs)
      )
      |> Ash.create()
    end

    test "THEN a subject over 200 characters is refused" do
      assert {:error, _error} = submit_ticket_with(%{subject: String.duplicate("a", 201)})
      assert {:ok, _ticket} = submit_ticket_with(%{subject: String.duplicate("a", 200)})
    end

    test "THEN a body over 5000 characters is refused" do
      assert {:error, _error} = submit_ticket_with(%{body: String.duplicate("a", 5_001)})
      assert {:ok, _ticket} = submit_ticket_with(%{body: String.duplicate("a", 5_000)})
    end
  end
end
