defmodule AshGrpc.Domain.Rpc do
  @moduledoc "An `rpc` or `subscription` entry of a domain's `grpc` block; `stream?` is true for a subscription."
  defstruct [
    :name,
    :resource,
    :action,
    :read_action,
    args: nil,
    reserved: [],
    clear_fields: nil,
    page: nil,
    sort: nil,
    filter: nil,
    load: [],
    deprecated: false,
    bulk?: false,
    max_bulk_size: nil,
    streaming: nil,
    max_stream_failures: nil,
    stream?: false,
    action_defaulted?: false,
    __spark_metadata__: nil
  ]

  @doc false
  def reject_resource(rpc) do
    if match?("Elixir." <> _, to_string(rpc.name)) do
      {:error,
       "inside `resource` the resource is already given: `rpc #{inspect(rpc.action || :name)}`."}
    else
      {:ok, rpc}
    end
  end

  @doc false
  def default_action(%{resource: resource} = rpc) do
    cond do
      not match?("Elixir." <> _, to_string(resource)) ->
        {:error,
         "resource comes first: `rpc MyApp.Post, :name`, not " <>
           "`rpc #{inspect(resource)}, #{inspect(rpc.name)}`."}

      rpc.action == nil ->
        {:ok, %{rpc | action: rpc.name, action_defaulted?: true}}

      true ->
        {:ok, rpc}
    end
  end

  @type t :: %__MODULE__{
          name: atom(),
          resource: module(),
          action: atom(),
          read_action: atom() | nil,
          args: [atom() | {atom(), pos_integer()}] | nil,
          reserved: [pos_integer()],
          clear_fields: boolean() | pos_integer() | nil,
          page: boolean() | [atom() | {atom(), pos_integer()}] | nil,
          sort: boolean() | pos_integer() | nil,
          filter: boolean() | pos_integer() | nil,
          load: atom() | list(),
          deprecated: boolean(),
          bulk?: boolean(),
          max_bulk_size: pos_integer() | nil,
          streaming: :client | :bidirectional | nil,
          max_stream_failures: pos_integer() | nil,
          stream?: boolean(),
          action_defaulted?: boolean()
        }
end
