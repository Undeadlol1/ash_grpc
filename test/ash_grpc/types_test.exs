defmodule AshGrpc.TypesTest do
  use ExUnit.Case, async: true

  alias AshGrpc.Types
  alias Google.Protobuf.Timestamp

  @kinds [:string, :atom, :int64, :double, :bool, :timestamp, :date, :decimal]

  test "every kind encodes nil as nil" do
    for kind <- @kinds, do: assert(Types.encode(kind, nil) == nil)
  end

  test "strings, integers and booleans cross unchanged" do
    assert Types.encode(:string, "hi") == "hi"
    assert Types.encode(:int64, 7) == 7
    assert Types.encode(:bool, false) == false
  end

  test "a double encodes an integer as a float" do
    assert Types.encode(:double, 3) === 3.0
    assert Types.encode(:double, 2.5) === 2.5
  end

  test "an atom encodes as its name" do
    assert Types.encode(:atom, :live) == "live"
  end

  test "a date encodes as ISO 8601 text" do
    assert Types.encode(:date, ~D[2026-11-11]) == "2026-11-11"
  end

  test "a decimal encodes as text" do
    assert Types.encode(:decimal, Decimal.new("9.99")) == "9.99"
  end

  test "a timestamp encodes seconds and nanos, also before 1970" do
    assert Types.encode(:timestamp, ~U[2027-01-15 08:00:00.123456Z]) ==
             %Timestamp{seconds: DateTime.to_unix(~U[2027-01-15 08:00:00Z]), nanos: 123_456_000}

    assert Types.encode(:timestamp, ~U[1969-12-31 23:59:59.500000Z]) ==
             %Timestamp{seconds: -1, nanos: 500_000_000}
  end

  test "a timestamp decodes back to the same instant" do
    instant = ~U[2027-01-15 08:00:00.123456Z]
    {:ok, decoded} = Types.decode(:timestamp, Types.encode(:timestamp, instant))

    assert DateTime.compare(decoded, instant) == :eq
  end

  test "a timestamp outside the date range does not decode" do
    assert {:error, _message} =
             Types.decode(:timestamp, %Timestamp{seconds: 999_999_999_999_999, nanos: 0})
  end

  test "a timestamp with nanos outside 0..999_999_999 does not decode" do
    assert {:error, _message} = Types.decode(:timestamp, %Timestamp{seconds: 0, nanos: -1})

    assert {:error, _message} =
             Types.decode(:timestamp, %Timestamp{seconds: 0, nanos: 1_000_000_000})
  end

  test "every other kind decodes to itself for Ash to cast" do
    for {kind, value} <- [string: "x", int64: 1, double: 1.5, bool: true, date: "nope"] do
      assert Types.decode(kind, value) == {:ok, value}
    end
  end
end
