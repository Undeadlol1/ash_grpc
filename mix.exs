defmodule AshGrpc.MixProject do
  use Mix.Project

  @source_url "https://github.com/Undeadlol1/ash_grpc"
  @version "0.1.0"

  def project do
    [
      app: :ash_grpc,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      docs: &docs/0,
      aliases: aliases(),
      description:
        "Ash extension: expose actions over gRPC, with messages, service and .proto derived.",
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => @source_url},
        files:
          ~w(lib documentation .formatter.exs mix.exs README.md CHANGELOG.md LICENSE usage-rules.md)
      ],
      name: "AshGrpc",
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {AshGrpc.Application, []}]
  end

  defp aliases do
    [
      docs: ["spark.cheat_sheets", "docs", "spark.replace_doc_links"],
      "spark.formatter": "spark.formatter --extensions AshGrpc.Resource,AshGrpc.Domain",
      "spark.cheat_sheets": "spark.cheat_sheets --extensions AshGrpc.Resource,AshGrpc.Domain"
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp docs do
    [
      main: "readme",
      source_ref: "main",
      extras: [
        {"README.md", title: "Home"},
        "documentation/tutorials/getting-started.md",
        "documentation/topics/actions.md",
        "documentation/topics/types.md",
        "documentation/topics/pagination-sort-filter.md",
        "documentation/topics/bulk-calls.md",
        "documentation/topics/streaming-calls.md",
        "documentation/topics/authentication.md",
        "documentation/topics/generating-clients.md",
        "documentation/topics/browser-grpc-web.md",
        "documentation/topics/interceptors-and-response-meta.md",
        "documentation/topics/errors.md",
        "documentation/topics/subscriptions.md",
        "documentation/topics/evolving-your-schema.md",
        "documentation/topics/reflection.md",
        "documentation/topics/health.md",
        "documentation/topics/tls.md",
        "documentation/topics/production.md",
        "documentation/topics/compression.md",
        "documentation/topics/testing.md",
        {"documentation/dsls/DSL-AshGrpc.Resource.md",
         search_data: Spark.Docs.search_data_for(AshGrpc.Resource)},
        {"documentation/dsls/DSL-AshGrpc.Domain.md",
         search_data: Spark.Docs.search_data_for(AshGrpc.Domain)},
        "usage-rules.md",
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        Tutorials: ~r"documentation/tutorials",
        Topics: ~r"documentation/topics",
        DSLs: ~r"documentation/dsls",
        "About AshGrpc": ["usage-rules.md", "CHANGELOG.md"]
      ],
      groups_for_modules: [
        "Public API": [
          AshGrpc.Resource,
          AshGrpc.Domain,
          AshGrpc.Endpoint,
          AshGrpc.Authenticator,
          AshGrpc.Notifier
        ],
        Configuration: [AshGrpc.Resource.Info, AshGrpc.Domain.Info],
        "Tools and model": [
          AshGrpc.Proto,
          AshGrpc.Proto.Compatibility,
          AshGrpc.Schema,
          AshGrpc.Types,
          AshGrpc.Errors,
          Mix.Tasks.AshGrpc.Gen.Protos
        ],
        "DSL structs": [AshGrpc.Domain.Service, AshGrpc.Domain.Rpc]
      ]
    ]
  end

  defp deps do
    [
      {:ash, "~> 3.22"},
      {:spark, "~> 2.3"},
      {:igniter, "~> 0.6", optional: true},
      {:jason, "~> 1.4"},
      {:grpc, "~> 1.1"},
      {:grpc_server, "~> 1.1"},
      {:protobuf, "~> 0.16"},
      {:gun, "~> 2.4", only: :test},
      {:grpc_reflection, "~> 0.5", optional: true},
      {:picosat_elixir, "~> 0.2", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
