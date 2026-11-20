defmodule AshGrpc.ListQueryTest do
  use ExUnit.Case, async: false

  alias AshGrpc.Examples.SupportDesk
  alias AshGrpc.Examples.SupportTicket
  alias AshGrpc.ListQuery

  setup do
    {:ok, _} = SupportDesk.submit_ticket("printer broken", "paper jam")
    {:ok, _} = SupportDesk.submit_ticket("scanner jam", "toner spill")
    {:ok, _} = SupportDesk.submit_ticket("laptop slow", "needs ram")
    :ok
  end

  describe "GIVEN the list query" do
    test "WHEN order_by names a field THEN the tickets come back sorted by it" do
      assert {:ok, query} = ListQuery.build(SupportTicket, %{order_by: "subject"})
      assert {:ok, tickets} = Ash.read(query)

      subjects = Enum.map(tickets, & &1.subject)
      assert subjects == Enum.sort(subjects)
    end

    test "WHEN order_by has a leading dash THEN the tickets come back sorted in descending order" do
      assert {:ok, query} = ListQuery.build(SupportTicket, %{order_by: "-subject"})
      assert {:ok, tickets} = Ash.read(query)

      subjects = Enum.map(tickets, & &1.subject)
      assert subjects == Enum.sort(subjects, :desc)
    end

    test "WHEN page_size and page_offset are given THEN one ticket from the offset is returned" do
      {:ok, all_query} = ListQuery.build(SupportTicket, %{order_by: "subject"})
      {:ok, all} = Ash.read(all_query)

      {:ok, page_query} =
        ListQuery.build(SupportTicket, %{order_by: "subject", page_size: 1, page_offset: 1})

      {:ok, page} = Ash.read(page_query)

      assert length(page) == 1
      assert hd(page).subject == Enum.at(all, 1).subject
    end

    test "WHEN a filter with string keys is given THEN only the matching ticket is returned" do
      unique_subject = "unique subject #{System.unique_integer([:positive])}"
      {:ok, _} = SupportDesk.submit_ticket(unique_subject, "body")

      assert {:ok, query} =
               ListQuery.build(SupportTicket, %{"filter" => %{"subject" => unique_subject}})

      assert {:ok, [ticket]} = Ash.read(query)
      assert ticket.subject == unique_subject
    end

    test "WHEN order_by names an unknown field THEN an error is returned instead of raising" do
      assert {:error, %Ash.Error.Invalid{}} =
               ListQuery.build(SupportTicket, %{order_by: "nonexistent_field"})
    end

    test "WHEN the request is empty THEN the query is unconstrained and returns every ticket" do
      assert {:ok, query} = ListQuery.build(SupportTicket, %{})
      assert {:ok, tickets} = Ash.read(query)
      assert length(tickets) >= 3
    end
  end
end
