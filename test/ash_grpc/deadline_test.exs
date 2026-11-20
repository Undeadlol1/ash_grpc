defmodule AshGrpc.DeadlineTest do
  use ExUnit.Case, async: true

  alias AshGrpc.Deadline
  alias AshGrpc.MetadataContext

  describe "GIVEN the client deadline WHEN a timeout is parsed" do
    test "THEN each supported unit becomes milliseconds" do
      assert Deadline.parse("100m") == {:ok, 100}
      assert Deadline.parse("2S") == {:ok, 2_000}
      assert Deadline.parse("3M") == {:ok, 180_000}
      assert Deadline.parse("1H") == {:ok, 3_600_000}
    end

    test "THEN a sub-millisecond deadline is rounded up to 1 ms" do
      assert Deadline.parse("500u") == {:ok, 1}
      assert Deadline.parse("999n") == {:ok, 1}
    end

    test "THEN a missing or malformed value is read as none" do
      assert Deadline.parse(nil) == :none
      assert Deadline.parse("") == :none
      assert Deadline.parse("100") == :none
      assert Deadline.parse("abc") == :none
      assert Deadline.parse("100X") == :none
      assert Deadline.parse("123456789S") == :none
    end
  end

  describe "GIVEN the client deadline WHEN a grpc-timeout header is read" do
    test "THEN the timeout is extracted from the grpc-timeout header" do
      assert Deadline.timeout_option(%{"grpc-timeout" => "250m"}) == {:timeout, 250}
    end

    test "THEN none is returned when the header is absent" do
      assert Deadline.timeout_option(%{"content-type" => "application/grpc"}) == :none
    end
  end

  describe "GIVEN the client deadline WHEN request metadata is merged into action options" do
    test "THEN an Ash timeout is derived from the grpc-timeout header" do
      assert {:ok, opts} =
               MetadataContext.merge_action_options(metadata: %{"grpc-timeout" => "500m"})

      assert Keyword.get(opts, :timeout) == 500
    end

    test "THEN an explicit timeout option overrides the header" do
      assert {:ok, opts} =
               MetadataContext.merge_action_options(
                 metadata: %{"grpc-timeout" => "500m"},
                 timeout: 42
               )

      assert Keyword.get(opts, :timeout) == 42
    end

    test "THEN no timeout is added when no deadline is present" do
      assert {:ok, opts} = MetadataContext.merge_action_options(metadata: %{})

      refute Keyword.has_key?(opts, :timeout)
    end
  end

  describe "GIVEN the client deadline WHEN the value is unreadable" do
    test "THEN an empty value, a non-numeric amount and an unknown unit are reported as none" do
      assert Deadline.parse("") == :none
      assert Deadline.parse("abcS") == :none
      assert Deadline.parse("5X") == :none
    end
  end
end
