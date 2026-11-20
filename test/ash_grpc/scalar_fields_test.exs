defmodule AshGrpc.ScalarFieldsTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.GrpcServer

  alias AshGrpc.TestSupport.Parcel
  alias AshGrpc.TestSupport.ParcelsEndpoint
  alias AshGrpc.TestSupport.ParcelsEndpoint.Parcels.V1
  alias AshGrpc.TestSupport.ParcelsEndpoint.Parcels.V1.Parcels.Stub
  alias AshGrpc.Types
  alias Google.Protobuf.Timestamp
  alias Google.Rpc.BadRequest
  alias GRPC.RPCError
  alias GRPC.Status

  describe "kinds" do
    test "binary types are bytes" do
      assert Types.kind(:binary) == {:ok, :bytes}
      assert Types.proto_type(:bytes) == "bytes"
    end

    test "times, durations and naive datetimes are ISO 8601 strings" do
      for type <- [:time, :time_usec, :duration, :naive_datetime] do
        assert {:ok, kind} = Types.kind(type)
        assert Types.proto_type(kind) == "string"
        refute Types.message?(kind)
      end
    end

    test "a datetime in any zone is a timestamp" do
      assert Types.kind(:datetime) == {:ok, :timestamp}
    end

    test "types with no faithful mapping are rejected with a reason" do
      for type <- [
            :term,
            :tuple,
            :function,
            :module,
            :vector,
            :file,
            :range,
            :struct,
            :keyword
          ] do
        assert {:error, reason} = Types.kind(type)
        assert is_binary(reason)
      end
    end

    test "a duration name is an enum named after its type" do
      assert {:ok, {:enum, %{name: "DurationName", values: [%{value: :year} | _]}}} =
               Types.kind(:duration_name)
    end
  end

  describe "url encoded binaries" do
    test "are unpadded URL-safe base64 text, as Ash casts them" do
      assert {:ok, kind} = Types.kind(:url_encoded_binary)
      assert Types.proto_type(kind) == "string"
      assert Types.encode(kind, <<251, 255>>) == "-_8"
    end
  end

  describe "values" do
    test "times, durations and naive datetimes encode as ISO 8601" do
      assert Types.encode(:time, ~T[08:30:00.123456]) == "08:30:00.123456"
      assert Types.encode(:duration, Duration.new!(month: 1, hour: 2)) == "P1MT2H"
      assert Types.encode(:naive_datetime, ~N[2026-11-12 08:30:00]) == "2026-11-12T08:30:00"
    end

    test "a datetime in another zone encodes as the same instant" do
      zoned = %{
        ~U[2026-11-12 08:30:00Z]
        | time_zone: "Etc/GMT-2",
          zone_abbr: "+02",
          utc_offset: 7200
      }

      assert Types.encode(:timestamp, zoned) ==
               %Timestamp{seconds: DateTime.to_unix(~U[2026-11-12 06:30:00Z]), nanos: 0}
    end

    test "bytes cross unchanged" do
      assert Types.encode(:bytes, <<0, 255>>) == <<0, 255>>
      assert Types.decode(:bytes, <<0, 255>>) == {:ok, <<0, 255>>}
    end
  end

  describe "proto" do
    test "the scalars render with their wire types" do
      [{_path, text}] = AshGrpc.Proto.render(ParcelsEndpoint)

      assert text =~ "  optional bytes photo = 2;"
      assert text =~ "  optional string pickup = 3;"
      assert text =~ "  optional string transit = 5;"
      assert text =~ "  optional string packed_at = 6;"
      assert text =~ "  google.protobuf.Timestamp shipped_at = 7;"
      assert text =~ "  optional string token = 8;"
    end
  end

  describe "over a real connection" do
    setup do
      %{channel: start(ParcelsEndpoint)}
    end

    test "attributes round trip through a create", %{channel: channel} do
      shipped_at = DateTime.to_unix(~U[2026-11-12 09:00:00Z])

      request = %V1.CreateParcelRequest{
        photo: <<0, 1, 255>>,
        pickup: "08:30:00",
        pickup_usec: "08:30:00.000123",
        transit: "P1DT2H",
        packed_at: "2026-11-12T07:00:00",
        shipped_at: %Timestamp{seconds: shipped_at, nanos: 0},
        token: "c2VjcmV0"
      }

      assert {:ok, %{result: parcel}} =
               Stub.create_parcel(channel, request, metadata: signed_in("someone"))

      assert parcel.photo == <<0, 1, 255>>
      assert parcel.pickup == "08:30:00"
      assert parcel.pickup_usec == "08:30:00.000123"
      assert parcel.transit == "P1DT2H"
      assert parcel.packed_at == "2026-11-12T07:00:00"
      assert parcel.shipped_at == %Timestamp{seconds: shipped_at, nanos: 0}
      assert parcel.token == "c2VjcmV0"

      assert %Parcel{transit: %Duration{day: 1, hour: 2}, pickup: ~T[08:30:00], token: "secret"} =
               Ash.get!(Parcel, parcel.id, authorize?: false)
    end

    test "arguments round trip through a create", %{channel: channel} do
      assert {:ok, %{result: parcel}} =
               Stub.pack_parcel(
                 channel,
                 %V1.PackParcelRequest{blob: <<7>>, at: "23:59:59", lasts: "PT30M"},
                 metadata: signed_in("someone")
               )

      assert {parcel.photo, parcel.pickup, parcel.transit} == {<<7>>, "23:59:59", "PT30M"}
    end

    test "unset fields stay unset", %{channel: channel} do
      assert {:ok, %{result: parcel}} =
               Stub.create_parcel(channel, %V1.CreateParcelRequest{},
                 metadata: signed_in("someone")
               )

      assert {parcel.photo, parcel.pickup, parcel.transit, parcel.shipped_at} ==
               {nil, nil, nil, nil}
    end

    test "a malformed time is INVALID_ARGUMENT naming the field", %{channel: channel} do
      assert {:error, %RPCError{status: status, details: [detail | _]}} =
               Stub.create_parcel(channel, %V1.CreateParcelRequest{pickup: "noon"},
                 metadata: signed_in("someone")
               )

      assert status == Status.invalid_argument()
      assert %BadRequest{field_violations: [%{field: "pickup"}]} = BadRequest.decode(detail.value)
    end
  end
end
