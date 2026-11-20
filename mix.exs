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
      aliases: aliases(),
      docs: &docs/0,
      description: description(),
      package: package(),
      name: "AshGrpc",
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.22"},
      {:spark, "~> 2.3"},
      {:grpc, "~> 1.0"},
      {:grpc_server, "~> 1.0"},
      {:grpc_reflection, "~> 0.5"},
      # GRPC.Stub.connect/2 defaults to the Gun adapter, whose transport grpc 1.0
      # made optional, so a client has to bring gun itself.
      {:gun, "~> 2.4", only: [:dev, :test]},
      {:protobuf, "~> 0.16"},
      {:jason, "~> 1.4"},
      # Only for `AshGrpc.PubSubSource`.
      {:phoenix_pubsub, "~> 2.1", optional: true},
      {:phoenix, "~> 1.7", only: :test},
      # Ash needs a SAT solver to evaluate policies; the suite has resources
      # with policies, so it is a test-only dependency here rather than
      # something this package imposes on its users.
      {:picosat_elixir, "~> 0.2", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      # Only for `mix spark.cheat_sheets`, which generates the DSL reference.
      {:igniter, "~> 0.6", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      "spark.cheat_sheets": "spark.cheat_sheets --extensions AshGrpc.Domain",
      docs: ["spark.cheat_sheets", "docs"]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        {"README.md", title: "Home"},
        "documentation/topics/authentication.md",
        "documentation/topics/streaming.md",
        "documentation/topics/proto-files.md",
        {"documentation/dsls/DSL-AshGrpc.Domain.md",
         search_data: Spark.Docs.search_data_for(AshGrpc.Domain)},
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        Topics: ~r"documentation/topics",
        Reference: ~r"documentation/dsls",
        "About AshGrpc": ["CHANGELOG.md"]
      ]
    ]
  end

  defp description do
    "Serves Ash actions over gRPC: declare routes on an Ash domain and map protobuf requests to Ash inputs and results back."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files:
        ~w(lib documentation .formatter.exs mix.exs README.md CHANGELOG.md LICENSE usage-rules.md)
    ]
  end
end
