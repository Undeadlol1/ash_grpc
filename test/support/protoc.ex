defmodule AshGrpc.TestSupport.Protoc do
  @moduledoc false

  def path, do: System.find_executable("protoc") || existing("/opt/homebrew/bin/protoc")

  def exclusions, do: if(path(), do: [], else: [:protoc])

  defp existing(path), do: if(File.exists?(path), do: path)
end
