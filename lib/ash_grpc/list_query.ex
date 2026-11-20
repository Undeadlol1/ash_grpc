defmodule AshGrpc.ListQuery do
  @moduledoc """
  Translates a standard gRPC list request into an `Ash.Query`.

  Read actions expose filtering, sorting and pagination. This module
  defines the conventional request shape (an AIP-158-style page_size / page_offset / order_by /
  filter) and turns it into a safe `Ash.Query`, using Ash's *input*
  builders (`sort_input`, `filter_input`) which are designed for
  untrusted external values.

  Request keys (all optional):

    * `:order_by` — comma-separated sort string, e.g. `"status,-subject"`
      or `"subject desc"`.
    * `:page_size` — positive integer row limit.
    * `:page_offset` — non-negative integer offset.
    * `:filter` — a map of field => value applied as input filters.

  A request built from a protobuf message (string keys) or in code (atom
  keys) both work.
  """

  @spec build(Ash.Resource.t() | Ash.Query.t(), map()) ::
          {:ok, Ash.Query.t()} | {:error, Ash.Error.t()}
  def build(resource_or_query, request) when is_map(request) do
    query =
      resource_or_query
      |> Ash.Query.new()
      |> apply_filter(fetch(request, :filter))
      |> apply_sort(fetch(request, :order_by))
      |> apply_limit(fetch(request, :page_size))
      |> apply_offset(fetch(request, :page_offset))

    if query.valid? do
      {:ok, query}
    else
      {:error, Ash.Error.to_error_class(query.errors)}
    end
  end

  defp apply_filter(query, filter) when is_map(filter) and map_size(filter) > 0 do
    Ash.Query.filter_input(query, filter)
  end

  defp apply_filter(query, _filter), do: query

  defp apply_sort(query, order_by) when is_binary(order_by) and order_by != "" do
    Ash.Query.sort_input(query, order_by)
  end

  defp apply_sort(query, _order_by), do: query

  defp apply_limit(query, page_size) when is_integer(page_size) and page_size > 0 do
    Ash.Query.limit(query, page_size)
  end

  defp apply_limit(query, _page_size), do: query

  defp apply_offset(query, page_offset) when is_integer(page_offset) and page_offset > 0 do
    Ash.Query.offset(query, page_offset)
  end

  defp apply_offset(query, _page_offset), do: query

  defp fetch(request, key) do
    Map.get(request, key) || Map.get(request, to_string(key))
  end
end
