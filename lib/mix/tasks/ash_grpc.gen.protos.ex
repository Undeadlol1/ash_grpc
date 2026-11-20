defmodule Mix.Tasks.AshGrpc.Gen.Protos do
  @shortdoc "Generates .proto files from ash_grpc domain route declarations"

  @moduledoc """
  Serializes the gRPC descriptors ash_grpc derives from a domain's routes
  into `.proto` source files, so a Dart/Flutter (or any) client can be
  generated from them.

      mix ash_grpc.gen.protos \\
        --domain MyApp.Support \\
        --service MyApp.Support.V1.Tickets.Service \\
        --output priv/protos

  Options:

    * `--domain` (required) — the Ash domain with an `AshGrpc.Domain` extension.
    * `--service` (required, repeatable) — a gRPC service module declared for
      that domain.
    * `--output` — directory to write into (default: `priv/protos`).
    * `--check` — do not write; fail if generated output differs from disk
      (for CI drift detection).

  Files are laid out by package path, e.g. `my_app/support/v1/tickets.proto`.
  """

  use Mix.Task

  alias AshGrpc.ProtoExporter
  alias AshGrpc.Reflection

  @switches [domain: :string, service: :keep, output: :string, check: :boolean]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.config")

    {opts, _args} = OptionParser.parse!(argv, switches: @switches)

    domain = resolve_domain(opts)
    services = resolve_services(opts)
    output_dir = Keyword.get(opts, :output, "priv/protos")

    files = generate_files(domain, services)

    if Keyword.get(opts, :check, false) do
      check_files(files, output_dir)
    else
      write_files(files, output_dir)
    end

    :ok
  end

  @doc false
  @spec generate_files(module(), [module()]) :: [{Path.t(), String.t()}]
  def generate_files(domain, services) do
    domain
    |> Reflection.descriptor_set(services: services)
    |> Map.fetch!(:file)
    |> Enum.map(fn file -> {file.name, ProtoExporter.to_proto_source(file)} end)
  end

  defp resolve_domain(opts) do
    case Keyword.get(opts, :domain) do
      nil -> Mix.raise("--domain is required")
      domain -> Module.concat([domain])
    end
  end

  defp resolve_services(opts) do
    case Keyword.get_values(opts, :service) do
      [] -> Mix.raise("at least one --service is required")
      services -> Enum.map(services, &Module.concat([&1]))
    end
  end

  defp write_files(files, output_dir) do
    Enum.each(files, fn {relative_path, source} ->
      path = Path.join(output_dir, relative_path)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, source)
      Mix.shell().info("ash_grpc wrote proto file #{path}")
    end)
  end

  defp check_files(files, output_dir) do
    drifted =
      Enum.filter(files, fn {relative_path, source} ->
        path = Path.join(output_dir, relative_path)
        File.read(path) != {:ok, source}
      end)

    if drifted == [] do
      Mix.shell().info("ash_grpc protos are up to date")
    else
      paths = Enum.map_join(drifted, "\n", fn {relative_path, _} -> "  #{relative_path}" end)

      Mix.raise(
        "generated ash_grpc protos differ from disk:\n#{paths}\nRun mix ash_grpc.gen.protos"
      )
    end
  end
end
