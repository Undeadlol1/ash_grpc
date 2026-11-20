defmodule AshGrpc.SubscriptionTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.GrpcServer
  import ExUnit.CaptureLog

  alias AshGrpc.TestSupport.GrpcWebClient
  alias AshGrpc.TestSupport.Note
  alias AshGrpc.TestSupport.NotesEndpoint
  alias AshGrpc.TestSupport.NotesEndpoint.Notes.V1
  alias GRPC.RPCError
  alias GRPC.Status
  alias V1.Notes.Stub

  setup do
    %{channel: start(NotesEndpoint), author: "author#{System.unique_integer([:positive])}"}
  end

  defp write!(author, title, tenant \\ "acme") do
    Note
    |> Ash.Changeset.for_create(:create, %{title: title, author: author}, tenant: tenant)
    |> Ash.create!(authorize?: false)
  end

  defp update!(note, changes) do
    note
    |> Ash.Changeset.for_update(:update, changes, tenant: note.organization)
    |> Ash.update!(authorize?: false)
  end

  defp destroy!(note) do
    note
    |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: note.organization)
    |> Ash.destroy!(authorize?: false)
  end

  defp watch(channel, rpc, request, metadata, opts \\ []) do
    test = self()

    spawn_link(fn ->
      case apply(Stub, rpc, [channel, request, [metadata: metadata] ++ opts]) do
        {:ok, replies} ->
          Enum.each(replies, &send(test, {:reply, &1}))
          send(test, :ended)

        error ->
          send(test, {:reply, error})
      end
    end)
  end

  defp watch_notes(channel, author, extra \\ %{}, opts \\ []) do
    watch(channel, :watch_notes, %V1.WatchNotesRequest{}, signed_in(author, extra), opts)
  end

  defp next_reply do
    assert_receive {:reply, reply}, 2_000
    reply
  end

  defp next_note do
    assert {:ok, %V1.WatchNotesResponse{removed: false, result: note}} = next_reply()
    note
  end

  defp assert_synced do
    assert {:ok, %V1.WatchNotesResponse{synced: true, result: nil, removed: false}} = next_reply()
  end

  defp watching_with_one_note(channel, author, opts \\ []) do
    first = write!(author, "Already there")
    watch_notes(channel, author, %{}, opts)
    assert next_note().id == first.id
    assert_synced()
    first
  end

  defp new_subscriber(before) do
    assert [subscriber] = subscribers() -- before
    subscriber
  end

  defp subscribers, do: :pg.get_members(AshGrpc.Notifier, Note)

  defp unsubscribed?(subscriber, attempts \\ 100) do
    cond do
      subscriber not in subscribers() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(10)
        unsubscribed?(subscriber, attempts - 1)
    end
  end

  test "the snapshot sends every record the action returns", %{channel: channel, author: author} do
    first = write!(author, "First note")
    second = write!(author, "Second note")

    watch_notes(channel, author)

    received = [next_note(), next_note()]
    assert Enum.sort(Enum.map(received, & &1.id)) == Enum.sort([first.id, second.id])
    assert Enum.sort(Enum.map(received, & &1.title_length)) == [10, 11]
    assert_synced()
    refute_receive {:reply, _}, 100
  end

  test "an empty snapshot sends the marker first, then changes", %{
    channel: channel,
    author: author
  } do
    watch_notes(channel, author)
    assert_synced()

    created = write!(author, "Late note")
    assert next_note().id == created.id
  end

  test "a change arriving during the snapshot is delivered after the marker", %{
    channel: channel,
    author: author
  } do
    slow = write!(author, "slow")
    watch(channel, :watch_slow, %V1.WatchSlowRequest{}, signed_in(author))
    Process.sleep(100)
    during = write!(author, "During snapshot")

    assert {:ok, %V1.WatchSlowResponse{result: %{id: slow_id}}} = next_reply()
    assert slow_id == slow.id
    assert {:ok, %V1.WatchSlowResponse{synced: true}} = next_reply()
    assert {:ok, %V1.WatchSlowResponse{synced: false, result: %{id: during_id}}} = next_reply()
    assert during_id == during.id
  end

  test "a create and an update by another process arrive", %{channel: channel, author: author} do
    watching_with_one_note(channel, author)

    created = write!(author, "Fresh note")
    assert %{id: id, title: "Fresh note"} = next_note()
    assert id == created.id

    update!(created, %{title: "Fresh title"})
    assert %{id: ^id, title: "Fresh title", title_length: 11} = next_note()
  end

  test "every response carries the index the record has in the sorted list", %{
    channel: channel,
    author: author
  } do
    bravo = write!(author, "bravo")
    delta = write!(author, "delta")
    watch(channel, :watch_sorted, %V1.WatchSortedRequest{sort: "title"}, signed_in(author))

    assert {:ok, %{result: %{id: bravo_id}, position: 0}} = next_reply()
    assert {:ok, %{result: %{id: delta_id}, position: 1}} = next_reply()
    assert {bravo_id, delta_id} == {bravo.id, delta.id}
    assert {:ok, %{synced: true}} = next_reply()

    charlie = write!(author, "charlie")
    assert {:ok, %{removed: false, result: %{id: charlie_id}, position: 1}} = next_reply()
    assert charlie_id == charlie.id

    update!(delta, %{title: "alpha"})
    assert {:ok, %{removed: false, result: %{id: ^delta_id}, position: 0}} = next_reply()

    update!(delta, %{title: "zulu"})
    assert {:ok, %{removed: false, result: %{id: ^delta_id}, position: 2}} = next_reply()
  end

  test "a destroy arrives as removed with only the primary key", %{
    channel: channel,
    author: author
  } do
    first = watching_with_one_note(channel, author)

    destroy!(first)

    assert {:ok, %V1.WatchNotesResponse{removed: true, result: removed}} = next_reply()
    assert removed == %V1.Note{id: first.id}
  end

  test "a record the actor may not read never arrives", %{channel: channel, author: author} do
    watching_with_one_note(channel, author)

    hidden = write!(author <> "-other", "Not yours")
    update!(hidden, %{title: "Still not yours"})
    destroy!(hidden)
    visible = write!(author, "Yours")

    assert next_note().id == visible.id
    refute_received {:reply, _}
  end

  test "a record that leaves the actor's view arrives as removed", %{
    channel: channel,
    author: author
  } do
    first = watching_with_one_note(channel, author)

    update!(first, %{author: author <> "-new-owner"})

    assert {:ok, %{removed: true, result: %{id: id}, position: nil}} = next_reply()
    assert id == first.id
  end

  test "a record that stops matching the action filter arrives as removed", %{
    channel: channel,
    author: author
  } do
    matching = write!(author, "Kept apple")
    watch(channel, :watch_matching, %V1.WatchMatchingRequest{word: "apple"}, signed_in(author))
    assert {:ok, %V1.WatchMatchingResponse{result: %{id: id}}} = next_reply()
    assert id == matching.id
    assert {:ok, %{synced: true}} = next_reply()

    update!(matching, %{title: "Kept pear"})
    assert {:ok, %{removed: true, result: %{id: ^id}}} = next_reply()

    update!(matching, %{title: "Another pear"})
    other = write!(author, "Green apple")
    assert {:ok, %{removed: false, result: %{id: other_id}}} = next_reply()
    assert other_id == other.id
  end

  test "a change in another tenant is ignored", %{channel: channel, author: author} do
    watching_with_one_note(channel, author)

    write!(author, "Elsewhere", "globex")
    here = write!(author, "Here")

    assert next_note().id == here.id
    refute_received {:reply, _}
  end

  test "a change written with a tenant struct reaches its tenant's subscribers", %{
    channel: channel,
    author: author
  } do
    watching_with_one_note(channel, author)

    written = write!(author, "Via struct", %AshGrpc.TestSupport.Organization{slug: "acme"})

    assert next_note().id == written.id
  end

  test "the tenant from the authenticator scopes the snapshot", %{
    channel: channel,
    author: author
  } do
    write!(author, "At acme")
    globex = write!(author, "At globex", "globex")

    watch_notes(channel, author, %{"x-org" => "globex"})

    assert next_note().id == globex.id
    assert_synced()
    refute_receive {:reply, _}, 100
  end

  test "no credentials is UNAUTHENTICATED and joins nothing", %{channel: channel} do
    before = subscribers()
    watch(channel, :watch_notes, %V1.WatchNotesRequest{}, %{})

    assert {:error, %RPCError{status: status}} = next_reply()
    assert status == Status.unauthenticated()
    assert subscribers() == before
  end

  test "a missing required argument is INVALID_ARGUMENT", %{channel: channel, author: author} do
    watch(channel, :watch_matching, %V1.WatchMatchingRequest{}, signed_in(author))

    assert {:error, %RPCError{status: status}} = next_reply()
    assert status == Status.invalid_argument()
  end

  test "the deadline ends the stream and leaves no subscriber", %{
    channel: channel,
    author: author
  } do
    before = subscribers()
    watching_with_one_note(channel, author, timeout: 300)
    subscriber = new_subscriber(before)
    ref = Process.monitor(subscriber)

    assert {:error, %RPCError{status: status}} = next_reply()
    assert status == Status.deadline_exceeded()
    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
    assert unsubscribed?(subscriber)
  end

  defp open_watch(author) do
    write!(author, "Already there")
    before = subscribers()

    {conn, stream} =
      GrpcWebClient.open_stream(
        :ranch.get_port(inspect(NotesEndpoint)),
        "/notes.v1.Notes/WatchNotes",
        signed_in(author),
        %V1.WatchNotesRequest{}
      )

    {conn, stream, Process.monitor(new_subscriber(before)), before}
  end

  defp assert_subscriber_left(monitor, before) do
    assert_receive {:DOWN, ^monitor, :process, _, _}, 2_000
    :sys.get_state(AshGrpc.Notifier)
    assert subscribers() == before
  end

  test "a client that disconnects leaves no subscriber", %{author: author} do
    {conn, _stream, monitor, before} = open_watch(author)

    :gun.close(conn)

    assert_subscriber_left(monitor, before)
  end

  test "a client that cancels the call leaves no subscriber", %{author: author} do
    {conn, stream, monitor, before} = open_watch(author)

    :gun.cancel(conn, stream)

    assert_subscriber_left(monitor, before)
    :gun.close(conn)
  end

  test "a failing re-read ends the stream with the mapped status and logs once", %{
    channel: channel,
    author: author
  } do
    log =
      capture_log(fn ->
        calm = write!(author, "calm")
        watch(channel, :watch_exploding, %V1.WatchExplodingRequest{}, signed_in(author))
        assert {:ok, %{result: %{id: id}}} = next_reply()
        assert id == calm.id
        assert {:ok, %{synced: true}} = next_reply()
        write!(author, "boom")

        assert {:error, %RPCError{status: status, message: "Internal error"}} = next_reply()
        assert status == Status.internal()
      end)

    assert [_once] = Regex.scan(~r/disk on fire/, log)
  end

  test "a subscription streams over gRPC-Web", %{author: author} do
    note = write!(author, "Over the web")
    port = :ranch.get_port(inspect(NotesEndpoint))

    response =
      GrpcWebClient.post(
        port,
        "/notes.v1.Notes/WatchNotes",
        signed_in(author, %{"grpc-timeout" => "300m"}),
        %V1.WatchNotesRequest{}
      )

    assert %V1.WatchNotesResponse{result: %{id: id}} =
             GrpcWebClient.data_frame(V1.WatchNotesResponse, response.body)

    assert id == note.id

    assert GrpcWebClient.trailer_frame(response.body)["grpc-status"] ==
             Integer.to_string(Status.deadline_exceeded())
  end
end
