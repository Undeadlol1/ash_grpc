defmodule AshGrpc.TestSupport.UnaryGreeting do
  @moduledoc false

  use Ash.Resource, data_layer: :embedded

  actions do
    create :create do
      accept([:message])
    end
  end

  attributes do
    attribute :message, :string do
      constraints(max_length: 20_000)
      allow_nil?(false)
      public?(true)
    end
  end
end

defmodule AshGrpc.TestSupport.UnaryGreetingRequest do
  @moduledoc false
  defstruct [:name]
end

defmodule AshGrpc.TestSupport.UnaryGreetingResponse do
  @moduledoc false
  defstruct [:message]
end

defmodule AshGrpc.TestSupport.UnaryDirectGreetingRequest do
  @moduledoc false
  defstruct [:message]
end

defmodule AshGrpc.TestSupport.UnaryPositionalGreetingRequest do
  @moduledoc false
  defstruct [:subject, :body, __unknown_fields__: []]
end

defmodule AshGrpc.TestSupport.UnaryGreetingRequestMapper do
  @moduledoc false

  alias AshGrpc.TestSupport.UnaryGreetingRequest

  def to_ash_input(%UnaryGreetingRequest{name: name}) when is_binary(name) do
    {:ok, %{message: "Hello, #{name}"}}
  end

  def to_ash_input(%UnaryGreetingRequest{name: nil}), do: {:ok, %{message: nil}}
end

defmodule AshGrpc.TestSupport.UnaryGreetingResponseMapper do
  @moduledoc false

  alias AshGrpc.TestSupport.UnaryGreeting
  alias AshGrpc.TestSupport.UnaryGreetingResponse

  def to_response(%UnaryGreeting{message: message}) do
    {:ok, %UnaryGreetingResponse{message: message}}
  end
end

defmodule AshGrpc.TestSupport.UnaryFailingRequestMapper do
  @moduledoc false

  def to_ash_input(_request) do
    {:error, Ash.Error.Changes.InvalidAttribute.exception(field: :name, message: "is required")}
  end
end

defmodule AshGrpc.TestSupport.UnaryFailingResponseMapper do
  @moduledoc false

  def to_response(_result) do
    {:error, RuntimeError.exception("response mapper exploded")}
  end
end

defmodule AshGrpc.TestSupport.UnaryDirectGreeting do
  @moduledoc false

  use Ash.Resource,
    domain: nil,
    data_layer: Ash.DataLayer.Ets

  ets do
    table(:ash_grpc_unary_test_direct_greetings)
  end

  actions do
    create :create do
      accept([:message])
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :message, :string do
      constraints(max_length: 20_000)
      allow_nil?(false)
      public?(true)
    end
  end
end

defmodule AshGrpc.TestSupport.UnaryPositionalGreeting do
  @moduledoc false

  use Ash.Resource,
    domain: nil,
    data_layer: Ash.DataLayer.Ets

  ets do
    table(:ash_grpc_unary_test_positional_greetings)
  end

  actions do
    create :create do
      accept([:subject, :body])
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :subject, :string do
      constraints(max_length: 1_000)
      allow_nil?(false)
      public?(true)
    end

    attribute :body, :string do
      constraints(max_length: 20_000)
      allow_nil?(false)
      public?(true)
    end
  end
end

defmodule AshGrpc.TestSupport.UnaryGreetingDesk do
  @moduledoc false

  use Ash.Domain,
    validate_config_inclusion?: false,
    extensions: [AshGrpc.Domain]

  alias AshGrpc.TestSupport.UnaryDirectGreeting

  grpc do
    routes do
      service "/greetings" do
        unary(:create_greeting, UnaryDirectGreeting, :create)
      end
    end
  end

  resources do
    resource UnaryDirectGreeting do
      define(:create_greeting, action: :create)
    end
  end
end

defmodule AshGrpc.TestSupport.UnaryPositionalGreetingDesk do
  @moduledoc false

  use Ash.Domain,
    validate_config_inclusion?: false,
    extensions: [AshGrpc.Domain]

  alias AshGrpc.TestSupport.UnaryPositionalGreeting

  grpc do
    routes do
      service "/positional-greetings" do
        unary(:submit_greeting, UnaryPositionalGreeting, :create)
      end
    end
  end

  resources do
    resource UnaryPositionalGreeting do
      define(:submit_greeting, action: :create, args: [:subject, :body])
    end
  end
end
