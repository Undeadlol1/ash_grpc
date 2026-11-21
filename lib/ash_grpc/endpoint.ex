defmodule AshGrpc.Endpoint do
  @moduledoc """
  A gRPC endpoint derived from domains with `AshGrpc.Domain`.

      defmodule MyAppWeb.GrpcEndpoint do
        use AshGrpc.Endpoint,
          domains: [MyApp.Blog],
          authenticator: MyAppWeb.GrpcAuthenticator
      end

  At compile time it defines, under the endpoint module and the package
  (`MyAppWeb.GrpcEndpoint.Blog.V1.*` for package `blog.v1`):

    * a `Protobuf` message module per resource message, request and response,
    * per service, `<Service>.Service`, `<Service>.Server` and a client
      `<Service>.Stub`,

  and makes the endpoint itself a `GRPC.Endpoint` running those servers.
  Start it in a supervision tree:

      {MyAppWeb.GrpcEndpoint, port: 50051}

  ## Options

    * `:domains` (required) - domains that use `AshGrpc.Domain`, as a literal list or any
      expression that evaluates to one at compile time. An invalid
      `grpc` block stops the endpoint from compiling.
    * `:authenticator` (required) - a module implementing
      `AshGrpc.Authenticator`. It is the only source of identity.
    * `:interceptors` - `GRPC.Server.Interceptor` modules, `Mod` or
      `{Mod, opts}`, listed outermost first. They run after authentication.
      See the [Interceptors and response meta](interceptors-and-response-meta.md)
      guide.
    * `:cors` - `allow_origin: "https://app.example.com"`, or a
      `&Mod.fun/2` capture taking the request and the stream and returning
      the origin, lets browsers call the endpoint over gRPC-Web. CORS headers
      are set before authentication, a preflight is answered without the
      authenticator, interceptors or any action. The default is off. See
      [Calling from a browser](endpoint-options.md#calling-from-a-browser-grpc-web).
    * `:reflection` - `true` serves gRPC server reflection (v1 and v1alpha) for
      the endpoint's services, so `grpcurl` and Postman work without a `.proto`
      file. Needs `{:grpc_reflection, "~> 0.5"}` in your deps. Reflection calls
      are authenticated like every other call. The default is off. See
      [Server reflection](endpoint-options.md#server-reflection).
    * `:health` - `true` serves the standard `grpc.health.v1.Health` service.
      `Check` answers `SERVING` for an empty name and for every service the
      endpoint serves, `NOT_FOUND` for any other name; `Watch` sends the
      current status and stays open. Health calls need no credentials. The
      default is off. See [Health checks](endpoint-options.md#health-checks).
    * `:compressors` - `GRPC.Compressor` modules the generated servers accept
      and answer with, for example `[GRPC.Compressor.Gzip]`. A client that
      sends `grpc-encoding: gzip` is understood and answered with gzip. The
      default is `[]`: no compression, and a call that asks for one is
      refused. The health service does not take part. See
      [Compression](endpoint-options.md#compression).
    * `:max_subscriptions` - how many subscription streams this endpoint keeps
      open at once, on this node. One more is answered `RESOURCE_EXHAUSTED`.
      Each open subscription re-reads its list on every write to its resource,
      so this bounds that work. The default is `1000`. See
      [Subscriptions](subscriptions.md).
    * `:response_meta` - `true` gives every unary response message
      `optional string meta = 2;` (see `put_response_meta/2`). The default is
      `false` and changes nothing. Subscriptions never carry `meta`.

  Start options are those of `GRPC.Server.Supervisor`. Errors the library maps to a
  status are not logged by the server adapter; internal errors are logged once
  by `AshGrpc.Errors`.

  When `config :ash_grpc, proto_output: "priv/protos"` is set, the endpoint
  reads its committed `.proto` files from there while it compiles, to number
  fields listed without a number, and recompiles when they change.

  The endpoint also exports `__ash_grpc__/1` (`:domains`, `:response_meta`,
  and `:protos`, the rendered files with the numbers it serves), which
  `AshGrpc.Proto.render/2` and `mix ash_grpc.gen.protos` read.
  """

  alias AshGrpc.Types

  @meta_key {__MODULE__, :response_meta}

  @doc """
  Adds to the `meta` field of this call's response; for interceptors, on an
  endpoint with `response_meta: true` (anything else raises).

  `meta` is a map, or a zero-arity function returning a map or `nil`. The
  function is the form to use around `next`: it runs once the action and its
  loads have finished, just before the reply is built, in the process that
  handles the call (the one the interceptors run in). Calls to this function
  merge at the top level in call order, a later value winning a key; the result
  is sent as one JSON document in the `meta` string. A failed call sends no
  reply and so no meta. Nothing is sent when the merged map is empty.
  """
  @spec put_response_meta(%GRPC.Server.Stream{}, map() | (-> map() | nil)) :: :ok
  def put_response_meta(%GRPC.Server.Stream{endpoint: endpoint}, meta) do
    if !(is_atom(endpoint) and endpoint != nil and
           function_exported?(endpoint, :__ash_grpc__, 1) and
           endpoint.__ash_grpc__(:response_meta)) do
      raise ArgumentError,
            "put_response_meta/2 needs an endpoint that uses AshGrpc.Endpoint with `response_meta: true`"
    end

    meta = if is_function(meta, 0), do: meta, else: fn -> meta end
    Process.put(@meta_key, Process.get(@meta_key, []) ++ [meta])
    :ok
  end

  @doc false
  def take_response_meta do
    funs = Process.delete(@meta_key) || []

    case funs |> Enum.map(& &1.()) |> Enum.reduce(%{}, &Map.merge(&2, &1 || %{})) do
      meta when map_size(meta) == 0 -> nil
      meta -> Jason.encode!(meta)
    end
  end

  defp domains_at_compile_time(domains, caller) when is_list(domains),
    do: Enum.map(domains, &Macro.expand(&1, caller))

  defp domains_at_compile_time(expression, caller) do
    {domains, _binding} = Code.eval_quoted(expression, [], caller)
    domains
  end

  @doc false
  defmacro __using__(opts) do
    domains = opts |> Keyword.fetch!(:domains) |> domains_at_compile_time(__CALLER__)
    authenticator = opts |> Keyword.fetch!(:authenticator) |> Macro.expand(__CALLER__)
    interceptors = Keyword.get(opts, :interceptors, [])
    response_meta? = Keyword.get(opts, :response_meta, false)
    cors = Keyword.get(opts, :cors)
    reflection? = Keyword.get(opts, :reflection, false)
    health? = Keyword.get(opts, :health, false)
    compressors = Keyword.get(opts, :compressors, [])
    max_subscriptions = Keyword.get(opts, :max_subscriptions, 1_000)
    if reflection?, do: ensure_reflection!()
    committed = committed_files(domains, Application.get_env(:ash_grpc, :proto_output))

    packages =
      AshGrpc.Schema.build(domains,
        response_meta: response_meta?,
        previous: committed && Map.new(committed, fn {path, _full, text} -> {path, text} end)
      )

    base = __CALLER__.module

    resources =
      for package <- packages,
          message <- package.messages,
          message.resource,
          uniq: true,
          do: message.resource

    definitions = Enum.flat_map(packages, &package_modules(base, &1, compressors))

    services =
      for package <- packages,
          service <- package.services,
          do: service_module(base, package, service, "Service")

    servers =
      for package <- packages,
          service <- package.services,
          do: service_module(base, package, service, "Server")

    reflection_servers =
      if reflection?, do: reflection_servers(base, services ++ health_services(health?)), else: []

    quote do
      use GRPC.Endpoint

      unquote_splicing(
        for {_path, full_path, _text} <- committed || [],
            do: quote(do: @external_resource(unquote(full_path)))
      )

      unquote_splicing(Enum.map(domains ++ resources, &quote(do: require(unquote(&1)))))
      unquote_splicing(definitions)
      unquote_splicing(Enum.map(reflection_servers, &reflection_definition/1))

      unquote(cors_intercept(cors))
      intercept(AshGrpc.Authenticator.Interceptor, unquote(authenticator))
      unquote_splicing(Enum.map(interceptors, &intercept_call/1))

      run(
        unquote(servers ++ health_servers(health?) ++ Enum.map(reflection_servers, & &1.module))
      )

      @doc false
      def __ash_grpc__(:domains), do: unquote(domains)
      def __ash_grpc__(:response_meta), do: unquote(response_meta?)
      def __ash_grpc__(:max_subscriptions), do: unquote(max_subscriptions)
      def __ash_grpc__(:protos), do: unquote(Macro.escape(AshGrpc.Proto.files(packages)))

      @doc "A child spec running this endpoint under `GRPC.Server.Supervisor`."
      def child_spec(opts) do
        server =
          GRPC.Server.Supervisor.child_spec(
            [
              endpoint: __MODULE__,
              start_server: true,
              exception_log_filter: {AshGrpc.Handler, :log_exception?}
            ] ++ opts
          )

        if unquote(reflection?),
          do: AshGrpc.Endpoint.with_reflection(__MODULE__, server),
          else: server
      end
    end
  end

  @reflection_hint ~s({:grpc_reflection, "~> 0.5"})

  @doc false
  def ensure_reflection!, do: ensure_reflection!(Code.ensure_loaded?(GrpcReflection.Server))

  @doc false
  def ensure_reflection!(true), do: :ok

  def ensure_reflection!(false) do
    raise ArgumentError,
          "`reflection: true` needs the grpc_reflection package; add #{@reflection_hint} to your deps"
  end

  @doc false
  def with_reflection(endpoint, server_spec) do
    reflection =
      if Process.whereis(GrpcReflection.Supervisor), do: [], else: [GrpcReflection]

    %{
      id: endpoint,
      type: :supervisor,
      start: {Supervisor, :start_link, [reflection ++ [server_spec], [strategy: :one_for_one]]}
    }
  end

  defp reflection_servers(base, services) do
    for {version, reflection_service} <- [
          v1: Grpc.Reflection.V1.ServerReflection.Service,
          v1alpha: Grpc.Reflection.V1alpha.ServerReflection.Service
        ] do
      %{
        module: Module.concat(base, "Reflection#{Macro.camelize(Atom.to_string(version))}"),
        version: version,
        services: services ++ [reflection_service]
      }
    end
  end

  defp health_services(true), do: [AshGrpc.Health.Service]
  defp health_services(false), do: []

  defp health_servers(true), do: [AshGrpc.Health.Server]
  defp health_servers(false), do: []

  defp reflection_definition(server) do
    quote do
      defmodule unquote(server.module) do
        @moduledoc false
        use GrpcReflection.Server,
          version: unquote(server.version),
          services: unquote(server.services)
      end
    end
  end

  defp committed_files(_domains, nil), do: nil

  defp committed_files(domains, output) do
    for domain <- domains, {:ok, package} <- [AshGrpc.Domain.Info.grpc_package(domain)] do
      path = AshGrpc.Schema.proto_file(package)
      full_path = Path.join(output, path)

      case File.read(full_path) do
        {:ok, text} -> {path, full_path, text}
        {:error, _reason} -> {path, full_path, nil}
      end
    end
  end

  defp cors_intercept(nil), do: nil
  defp cors_intercept(cors), do: quote(do: intercept(AshGrpc.Cors, unquote(cors)))

  defp intercept_call({interceptor, opts}),
    do: quote(do: intercept(unquote(interceptor), unquote(opts)))

  defp intercept_call(interceptor), do: quote(do: intercept(unquote(interceptor)))

  @doc false
  def message_module(base, package, name) do
    Module.concat(
      [base | Enum.map(String.split(package.package, "."), &Macro.camelize/1)] ++ [name]
    )
  end

  @doc false
  def service_module(base, package, service, suffix) do
    Module.concat(message_module(base, package, service.name), suffix)
  end

  defp package_modules(base, package, compressors) do
    rpc_messages =
      for service <- package.services,
          rpc <- service.rpcs,
          m <- AshGrpc.Schema.rpc_messages(rpc),
          do: m

    Enum.map(package.enums, &enum_definition(base, package, &1)) ++
      Enum.map(package.messages ++ rpc_messages, &message_definition(base, package, &1)) ++
      Enum.flat_map(package.services, &service_definitions(base, package, &1, compressors))
  end

  defp message_definition(base, package, message) do
    oneof? = Map.get(message, :oneof?, false)
    oneofs = message.fields |> Enum.map(& &1[:oneof]) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    fields =
      for field <- message.fields do
        type =
          case field.kind do
            {:message, name} -> message_module(base, package, name)
            {:enum_type, name} -> message_module(base, package, name)
            kind -> Types.field_type(kind)
          end

        opts =
          [type: type] ++
            if(field.repeated?, do: [repeated: true], else: []) ++
            if(match?({:enum_type, _name}, field.kind), do: [enum: true], else: []) ++
            if(oneof?, do: [oneof: 0], else: []) ++
            if(field[:oneof],
              do: [oneof: Enum.find_index(oneofs, &(&1 == field.oneof))],
              else: []
            ) ++
            if(Map.get(field, :deprecated?), do: [deprecated: true], else: []) ++
            if(field.optional? and not field.repeated? and not Types.message?(field.kind),
              do: [proto3_optional: true],
              else: []
            )

        quote do: field(unquote(field.name), unquote(field.number), unquote(opts))
      end

    quote do
      defmodule unquote(message_module(base, package, message.name)) do
        @moduledoc false
        use Protobuf, full_name: unquote("#{package.package}.#{message.name}"), syntax: :proto3

        unquote_splicing(oneof_declaration(oneof?))
        unquote_splicing(named_oneof_declarations(oneofs))
        unquote_splicing(fields)
      end
    end
  end

  defp enum_definition(base, package, enum) do
    values =
      for value <- enum.values,
          do: quote(do: field(unquote(String.to_atom(value.name)), unquote(value.number)))

    quote do
      defmodule unquote(message_module(base, package, enum.name)) do
        @moduledoc false
        use Protobuf,
          enum: true,
          full_name: unquote("#{package.package}.#{enum.name}"),
          syntax: :proto3

        unquote_splicing(values)
      end
    end
  end

  defp oneof_declaration(true), do: [quote(do: oneof(:value, 0))]
  defp oneof_declaration(false), do: []

  defp named_oneof_declarations(names) do
    for {name, index} <- Enum.with_index(names),
        do: quote(do: oneof(unquote(String.to_atom(name)), unquote(index)))
  end

  defp service_definitions(base, package, service, compressors) do
    service_mod = service_module(base, package, service, "Service")

    rpcs =
      for rpc <- service.rpcs do
        request = message_module(base, package, rpc.request.name)
        {reply, reply_streamed?} = reply_message(rpc)
        reply = message_module(base, package, reply)

        request = if rpc.streaming, do: quote(do: stream(unquote(request))), else: request
        reply = if reply_streamed?, do: quote(do: stream(unquote(reply))), else: reply

        quote do: rpc(unquote(String.to_atom(rpc.proto_name)), unquote(request), unquote(reply))
      end

    handlers =
      for rpc <- service.rpcs do
        function = rpc.proto_name |> Macro.underscore() |> String.to_atom()
        spec = handler_spec(base, package, rpc)

        quote do
          def unquote(function)(request, stream) do
            AshGrpc.Handler.handle(unquote(Macro.escape(spec)), request, stream)
          end
        end
      end

    [
      quote do
        defmodule unquote(service_mod) do
          @moduledoc false
          use GRPC.Service, name: unquote("#{package.package}.#{service.name}")

          unquote_splicing(rpcs)
        end
      end,
      quote do
        defmodule unquote(service_module(base, package, service, "Server")) do
          @moduledoc false
          use GRPC.Server, service: unquote(service_mod), compressors: unquote(compressors)

          unquote_splicing(handlers)
        end
      end,
      quote do
        defmodule unquote(service_module(base, package, service, "Stub")) do
          @moduledoc false
          use GRPC.Stub, service: unquote(service_mod)
        end
      end
    ]
  end

  defp reply_message(%{streaming: :bidirectional} = rpc), do: {rpc.proto_name <> "Reply", true}
  defp reply_message(%{streaming: :client} = rpc), do: {rpc.proto_name <> "Summary", false}
  defp reply_message(rpc), do: {rpc.response.name, rpc.stream?}

  defp handler_spec(base, package, rpc) do
    message = Enum.find(package.messages, &(&1.resource == rpc.resource))

    %{
      endpoint: base,
      resource: rpc.resource,
      action: rpc.action,
      action_type: rpc.action_type,
      result: rpc.result,
      result_field: Enum.find(rpc.response.fields, &(&1.name == :result)),
      read_action: rpc.read_action,
      many?: rpc.many?,
      paged?: rpc.paged?,
      page_fields: for(field <- rpc.response.fields, field[:source] == :page, do: field.name),
      stream?: rpc.stream?,
      streaming: rpc.streaming,
      max_stream_failures: rpc.max_stream_failures,
      reply_module: message_module(base, package, elem(reply_message(rpc), 0)),
      failure_module: message_module(base, package, rpc.proto_name <> "Failure"),
      request_fields: rpc.request.fields,
      response_module: message_module(base, package, rpc.response.name),
      response_meta?: Enum.any?(rpc.response.fields, &(&1.name == :meta)),
      message_module: message_module(base, package, message.name),
      message_fields: wire_fields(message),
      messages: wire_messages(base, package),
      loads: rpc.loads
    }
  end

  defp wire_messages(base, package) do
    messages =
      Map.new(package.messages, fn message ->
        {message.name,
         %{
           module: message_module(base, package, message.name),
           fields: wire_fields(message),
           oneof?: Map.get(message, :oneof?, false),
           shape: Map.get(message, :shape)
         }}
      end)

    Enum.reduce(package.enums, messages, fn enum, acc ->
      named = for %{value: value} = entry <- enum.values, value != nil, do: entry

      Map.put(acc, enum.name, %{
        to_proto:
          for(
            entry <- named,
            key <- [entry.value, to_string(entry.value)],
            into: %{},
            do: {key, String.to_atom(entry.name)}
          ),
        from_proto: Map.new(enum.values, &{String.to_atom(&1.name), &1.value})
      })
    end)
  end

  defp wire_fields(message),
    do: Enum.map(message.fields, &Map.take(&1, [:name, :kind, :optional?, :repeated?]))
end
