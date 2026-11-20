defmodule AshGrpc.Proto.CompatibilityTest do
  use ExUnit.Case, async: true

  alias AshGrpc.Proto.Compatibility

  defp proto(post_body, service_body \\ default_rpcs(), extra \\ "") do
    """
    syntax = "proto3";

    package blog.v1;

    message Post {
    #{String.trim_trailing(post_body)}
    }

    message ListPostsRequest {}

    message ListPostsResponse {
      repeated Post result = 1;
    }
    #{extra}
    service Posts {
    #{service_body}
    }
    """
  end

  defp default_rpcs, do: "  rpc ListPosts(ListPostsRequest) returns (ListPostsResponse);"

  @base """
    string id = 1;
    optional string title = 2;
    string body = 3;
  """

  describe "breaking changes" do
    test "a field number that now has another name" do
      new = String.replace(@base, "title = 2", "headline = 2")
      assert ["message Post: field 2 changed from `optional string title` to" <> _] = check(new)
    end

    test "a field number that now has another type" do
      new = String.replace(@base, "string body = 3", "int64 body = 3")

      assert ["message Post: field 3 changed from `string body` to `int64 body`" <> _] =
               check(new)
    end

    test "a field that became repeated" do
      new = String.replace(@base, "string body = 3", "repeated string body = 3")

      assert ["message Post: field 3 changed from `string body` to `repeated string body`" <> _] =
               check(new)
    end

    test "a field that stopped being optional" do
      new = String.replace(@base, "optional string title", "string title")
      assert [change] = check(new)
      assert change =~ "field 2 changed from `optional string title` to `string title`"
    end

    test "a field removed without reserving its number" do
      new = String.replace(@base, "  string body = 3;\n", "")
      assert [change] = check(new)
      assert change =~ "field 3 (`string body`) was removed"
      assert change =~ "Add `reserved 3` to Post"
    end

    test "a field removed while another number is reserved" do
      new = String.replace(@base, "  string body = 3;\n", "  reserved 9;\n")
      assert [change] = check(new)
      assert change =~ "field 3"
    end

    test "a reserved number that is no longer reserved" do
      old = proto(@base <> "  reserved 7;\n")
      assert [change] = Compatibility.check(old, proto(@base))
      assert change =~ "reserved number 7 is no longer reserved"
    end

    test "a reserved number that a field uses again" do
      old = proto(@base <> "  reserved 7;\n")
      assert [change] = Compatibility.check(old, proto(@base <> "  string slug = 7;\n"))
      assert change =~ "reserved number 7 is used by a field again"
    end

    test "a message that is gone" do
      old = proto(@base, default_rpcs(), "\nmessage Extra {}\n")
      assert ["message Extra was removed."] = Compatibility.check(old, proto(@base))
    end

    test "a service that is gone" do
      old =
        proto(@base) <>
          "\nservice Tags {\n  rpc ListPosts(ListPostsRequest) returns (ListPostsResponse);\n}\n"

      assert ["service Tags was removed."] = Compatibility.check(old, proto(@base))
    end

    test "an rpc that is gone" do
      old =
        proto(
          @base,
          default_rpcs() <> "\n  rpc Other(ListPostsRequest) returns (ListPostsResponse);"
        )

      assert ["service Posts: rpc Other was removed."] = Compatibility.check(old, proto(@base))
    end

    test "an rpc whose request type changed" do
      new = proto(@base, "  rpc ListPosts(ListPostsResponse) returns (ListPostsResponse);")
      assert [change] = Compatibility.check(proto(@base), new)
      assert change =~ "rpc ListPosts changed from (ListPostsRequest)"
    end

    test "an rpc whose response type changed" do
      new = proto(@base, "  rpc ListPosts(ListPostsRequest) returns (ListPostsRequest);")
      assert [change] = Compatibility.check(proto(@base), new)
      assert change =~ "returns (ListPostsRequest)."
    end

    test "a unary rpc that became a stream" do
      new = proto(@base, "  rpc ListPosts(ListPostsRequest) returns (stream ListPostsResponse);")
      assert [change] = Compatibility.check(proto(@base), new)
      assert change =~ "to (ListPostsRequest) returns (stream ListPostsResponse)."
    end

    test "a stream that became unary" do
      old = proto(@base, "  rpc ListPosts(ListPostsRequest) returns (stream ListPostsResponse);")
      assert [change] = Compatibility.check(old, proto(@base))
      assert change =~ "from (ListPostsRequest) returns (stream ListPostsResponse) to"
    end

    test "a subscription that is gone" do
      old =
        proto(
          @base,
          default_rpcs() <> "\n  rpc Watch(ListPostsRequest) returns (stream ListPostsResponse);"
        )

      assert ["service Posts: rpc Watch was removed."] = Compatibility.check(old, proto(@base))
    end

    test "every change is listed, in a stable order" do
      new =
        @base
        |> String.replace("  string body = 3;\n", "")
        |> String.replace("string id", "int64 id")

      assert [first, second] = check(new)
      assert first =~ "field 1"
      assert second =~ "field 3"
    end
  end

  describe "changes that are fine" do
    test "no change" do
      assert check(@base) == :ok
    end

    test "a new field with a new number" do
      assert check(@base <> "  optional string slug = 4;\n") == :ok
    end

    test "a new message, service and rpc" do
      new =
        proto(
          @base,
          default_rpcs() <> "\n  rpc Fresh(Fresh) returns (Fresh);",
          "\nmessage Fresh {}\n"
        ) <> "\nservice Fresh {\n  rpc Go(Fresh) returns (Fresh);\n}\n"

      assert Compatibility.check(proto(@base), new) == :ok
    end

    test "marking a field deprecated" do
      assert check(String.replace(@base, "title = 2", "title = 2 [deprecated = true]")) == :ok
    end

    test "an unchanged subscription, also once deprecated" do
      streamed = "  rpc ListPosts(ListPostsRequest) returns (stream ListPostsResponse)"
      deprecated = streamed <> " {\n    option deprecated = true;\n  }"

      assert Compatibility.check(proto(@base, streamed <> ";"), proto(@base, deprecated)) == :ok
    end

    test "marking an rpc deprecated" do
      new =
        proto(
          @base,
          "  rpc ListPosts(ListPostsRequest) returns (ListPostsResponse) {\n    option deprecated = true;\n  }"
        )

      assert Compatibility.check(proto(@base), new) == :ok
    end

    test "retiring a field by removing it and reserving its number" do
      new = String.replace(@base, "  string body = 3;\n", "  reserved 3;\n")
      assert check(new) == :ok
    end

    test "a message that only holds reserved numbers" do
      old = proto(@base, default_rpcs(), "\nmessage Gone {}\n")
      new = proto(@base, default_rpcs(), "\nmessage Gone {\n  reserved 1, 2;\n}\n")
      assert Compatibility.check(old, new) == :ok
    end
  end

  describe "comments" do
    test "adding, changing and removing comment lines is never breaking" do
      described = """
        // The id.
        string id = 1;
        // Changed title text.
        //
        // Second line.
        optional string title = 2;
        string body = 3;
      """

      rpcs = "  // Lists posts.\n" <> default_rpcs()

      assert Compatibility.check(proto(@base), proto(described, rpcs)) == :ok
      assert Compatibility.check(proto(described, rpcs), proto(@base)) == :ok
    end

    test "a comment line hides nothing: a real change beside it is still found" do
      new = "  // About body.\n" <> String.replace(@base, "string body = 3", "int64 body = 3")
      assert ["message Post: field 3 changed" <> _] = check(new)
    end
  end

  describe "text it cannot read" do
    test "raises and names the line" do
      assert_raise ArgumentError, ~r/line 3: "extend Color \{"/, fn ->
        Compatibility.check(proto(@base), "syntax = \"proto3\";\n\nextend Color {\n}\n")
      end
    end

    test "an unreadable field line inside a message is reported" do
      assert_raise ArgumentError, ~r/cannot read .proto line 6/, fn ->
        Compatibility.check(proto(@base), proto("  map<string, string> pairs = 1;\n"))
      end
    end
  end

  defp check(new_body), do: Compatibility.check(proto(@base), proto(new_body))
end
