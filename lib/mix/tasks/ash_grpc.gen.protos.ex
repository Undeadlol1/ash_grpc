defmodule Mix.Tasks.AshGrpc.Gen.Protos do
  @shortdoc "Writes the .proto files of an AshGrpc endpoint"

  @moduledoc """
  Writes one `.proto` file per package of an `AshGrpc.Endpoint`.

      mix ash_grpc.gen.protos
      mix ash_grpc.gen.protos --check
      mix ash_grpc.gen.protos --endpoint MyAppWeb.GrpcEndpoint --output priv/protos

  The endpoints and the output directory come from the application
  environment (`mix ash_grpc.install` sets them):

      config :ash_grpc,
        endpoints: [MyAppWeb.GrpcEndpoint],
        proto_output: "priv/protos"

  `--endpoint` and `--output` win over the configuration. Several endpoints
  write into the same directory. `mix ash.codegen` runs this task too. Two endpoints
  that render the same file with different content stop the task.

  With `--check` nothing is written; the task fails when a file on disk
  differs from what the endpoint would generate, or when a `.proto` file under
  the output directory is no longer rendered by the endpoint.

  When a file already exists, the task compares it with the new text using
  `AshGrpc.Proto.Compatibility`. If clients built from the old file would
  break, nothing is written and the task fails listing each change. Pass
  `--allow-breaking` to write anyway. A `.proto` file under the output
  directory that the endpoint no longer renders (a renamed package, a domain
  that left the endpoint) counts as breaking too, and is deleted only with
  `--allow-breaking`.
  """

  use Mix.Task

  alias AshGrpc.Proto.Compatibility

  @switches [endpoint: :string, output: :string, check: :boolean, allow_breaking: :boolean]

  @doc false
  def configured?, do: endpoints([]) != [] and not is_nil(output([]))

  defp endpoints(opts) do
    case opts[:endpoint] do
      nil -> Application.get_env(:ash_grpc, :endpoints, [])
      name -> [Module.concat([name])]
    end
  end

  defp output(opts), do: opts[:output] || Application.get_env(:ash_grpc, :proto_output)

  defp resolve!(opts) do
    endpoints = endpoints(opts)
    output = output(opts)

    if endpoints == [] or is_nil(output) do
      Mix.raise(
        "No endpoint or output directory. Pass --endpoint and --output, or configure them:\n\n" <>
          "    config :ash_grpc, endpoints: [MyAppWeb.GrpcEndpoint], proto_output: \"priv/protos\""
      )
    end

    {endpoints, output}
  end

  @impl Mix.Task
  def run(argv) do
    {opts, _args} = OptionParser.parse!(argv, strict: @switches)
    {endpoints, output} = resolve!(opts)

    Mix.Task.run("compile")

    files = render(endpoints)

    if opts[:check] do
      check(files, orphans(files, output), output)
    else
      orphans = orphans(files, output)
      if !opts[:allow_breaking], do: refuse_breaking(files, orphans, output)
      write(files, output)
      delete(orphans)
    end
  end

  defp render(endpoints) do
    rendered =
      for endpoint <- endpoints,
          {path, text} <- AshGrpc.Proto.render(endpoint),
          do: {path, text, endpoint}

    for {path, [{_, text, first} | others]} <- Enum.group_by(rendered, &elem(&1, 0)) do
      case Enum.find(others, fn {_, other, _} -> other != text end) do
        nil ->
          {path, text}

        {_, _, second} ->
          Mix.raise(
            "#{inspect(first)} and #{inspect(second)} both render #{path}, with different content. " <>
              "Give their domains different packages, or serve them from one endpoint."
          )
      end
    end
  end

  defp orphans(files, output) do
    rendered = MapSet.new(files, fn {path, _text} -> Path.join(output, path) end)

    output
    |> Path.join("**/*.proto")
    |> Path.wildcard()
    |> Enum.reject(&MapSet.member?(rendered, &1))
  end

  defp delete(orphans) do
    for path <- orphans do
      File.rm!(path)
      Mix.shell().info("Deleted #{path}")
    end
  end

  defp refuse_breaking(files, orphans, output) do
    breaking =
      for {path, text} <- files,
          full_path = Path.join(output, path),
          {:ok, old_text} <- [File.read(full_path)],
          change <- changes(old_text, text, full_path),
          do: "#{full_path}: #{change}"

    breaking = breaking ++ for path <- orphans, do: "#{path}: no longer rendered by the endpoint"

    if breaking != [] do
      Mix.raise(
        "Nothing written: these changes would break clients built from the committed files.\n" <>
          Enum.map_join(breaking, "\n", &("  - " <> &1)) <>
          "\nRetire a field by removing it and adding its number to `reserved`. " <>
          "Pass --allow-breaking to write anyway."
      )
    end
  end

  defp changes(old_text, new_text, full_path) do
    case Compatibility.check(old_text, new_text) do
      :ok -> []
      changes -> changes
    end
  rescue
    error in ArgumentError ->
      Mix.raise(
        "#{full_path} is not a file this task wrote: #{error.message}. Pass --allow-breaking to overwrite it."
      )
  end

  defp write(files, output) do
    for {path, text} <- files,
        full_path = Path.join(output, path),
        old = File.read(full_path),
        old != {:ok, text} do
      File.mkdir_p!(Path.dirname(full_path))
      File.write!(full_path, text)
      Mix.shell().info("Wrote #{full_path}")
      with {:ok, old_text} <- old, do: report_retired(old_text, text)
    end
  end

  defp report_retired(old_text, new_text) do
    old = Compatibility.parse(old_text)
    new = Compatibility.parse(new_text)

    for {name, message} <- Enum.sort(new.messages),
        %{fields: old_fields, reserved: old_reserved} <- [old.messages[name]],
        number <- message.reserved -- old_reserved,
        %{name: field} <- [old_fields[number]] do
      Mix.shell().info("Retired #{name}.#{field} (field #{number}); its number is now reserved.")
    end
  rescue
    ArgumentError -> :ok
  end

  defp check(files, orphans, output) do
    stale =
      for(
        {path, text} <- files,
        full_path = Path.join(output, path),
        File.read(full_path) != {:ok, text},
        do: full_path
      ) ++ orphans

    if stale != [] do
      Mix.raise(
        "These .proto files are out of date: #{Enum.join(stale, ", ")}. " <>
          "Run mix ash_grpc.gen.protos without --check."
      )
    end

    :ok
  end
end
