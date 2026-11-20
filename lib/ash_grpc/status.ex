defmodule AshGrpc.Status do
  @moduledoc """
  The `google.rpc.Status` message with a `full_name`, which the `googleapis`
  struct lacks and gRPC reflection needs to describe a field of this type.
  """

  use Protobuf, full_name: "google.rpc.Status", syntax: :proto3

  field :code, 1, type: :int32
  field :message, 2, type: :string
  field :details, 3, repeated: true, type: Google.Protobuf.Any
end
