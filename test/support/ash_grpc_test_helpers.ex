defmodule AshGrpc.TestHelpers do
  @moduledoc false

  def unique_integer, do: System.unique_integer([:positive])

  def maybe_sort_subjects(subjects, options) do
    if Keyword.get(options, :sort?, true) do
      Enum.sort(subjects)
    else
      subjects
    end
  end

  def method_named(routes, name) do
    Enum.find(routes, &(&1.name == name))
  end
end
