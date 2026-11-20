defmodule AshGrpc.TestSupport.Post do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.TestSupport.Blog,
    data_layer: Ash.DataLayer.Ets,
    authorizers: [Ash.Policy.Authorizer],
    primary_read_warning?: false,
    extensions: [AshGrpc.Resource]

  field_policies do
    field_policy :body do
      forbid_if actor_attribute_equals(:name, "hush-body")
      authorize_if always()
    end

    field_policy :title do
      forbid_if actor_attribute_equals(:name, "hush-title")
      authorize_if always()
    end

    field_policy :* do
      authorize_if always()
    end
  end

  grpc do
    proto_message "Post"

    fields id: 1,
           title: 2,
           body: 3,
           views: 4,
           rating: 5,
           published: 6,
           published_on: 7,
           price: 8,
           status: 9,
           inserted_at: 10,
           published_at: 11,
           title_length: 12,
           organization: 13,
           author_name: 14,
           slow_mark: 17

    reserved [15, 16]
    deprecated [:author_name]
  end

  actions do
    defaults [:destroy]

    read :read do
      primary? true

      prepare fn query, context ->
        case context.actor do
          %{name: "sleepy-lookup"} ->
            Ash.Query.after_action(query, fn _query, posts ->
              Process.sleep(1_000)
              {:ok, posts}
            end)

          _ ->
            query
        end
      end
    end

    read :unlocked do
      filter expr(title != "locked")
    end

    read :by_id do
      get? true
      argument :id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:id))
    end

    read :slow do
      prepare fn query, _context ->
        Ash.Query.after_action(query, fn _query, posts ->
          Process.sleep(300)
          {:ok, posts}
        end)
      end
    end

    read :paged do
      pagination offset?: true, required?: false, default_limit: 1
    end

    update :retitle do
      accept [:title]
      argument :id, :uuid, allow_nil?: false
    end

    create :create do
      primary? true
      accept [:title, :body, :rating, :published_on, :price, :status, :published_at]
      change set_attribute(:author_name, actor(:name))

      change fn changeset, _context ->
        case Process.get(AshGrpc.TestSupport.RecordingInterceptor) do
          nil -> changeset
          body -> Ash.Changeset.force_change_attribute(changeset, :body, body)
        end
      end
    end

    update :update do
      primary? true
      accept [:title, :body]
    end

    action :publish, :struct do
      constraints instance_of: __MODULE__
      argument :id, :uuid, allow_nil?: false

      run fn input, context ->
        opts = Ash.Context.to_opts(context)

        with {:ok, post} <- Ash.get(__MODULE__, input.arguments.id, opts) do
          post
          |> Ash.Changeset.for_update(:update, %{}, opts)
          |> Ash.Changeset.force_change_attribute(:published, true)
          |> Ash.update(opts)
        end
      end
    end

    action :vanish, :struct do
      constraints instance_of: __MODULE__
      allow_nil? true
      run fn _input, _context -> {:ok, nil} end
    end

    action :preloaded, :struct do
      constraints instance_of: __MODULE__
      run fn _input, _context -> {:ok, struct(__MODULE__, title: "kept", title_length: 99)} end
    end

    action :nap, :struct do
      constraints instance_of: __MODULE__

      run fn _input, _context ->
        Process.sleep(300)
        {:ok, struct(__MODULE__, title: "awake")}
      end
    end

    action :explode, :struct do
      constraints instance_of: __MODULE__
      run fn _input, _context -> raise "database password is hunter2" end
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(author_name == ^actor(:name))
    end

    policy action_type(:destroy) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy always() do
      authorize_if actor_present()
    end
  end

  validations do
    validate string_length(:title, min: 3)
  end

  multitenancy do
    strategy :attribute
    attribute :organization
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :body, :string, public?: true
    attribute :views, :integer, allow_nil?: false, default: 0, public?: true
    attribute :rating, :float, public?: true
    attribute :published, :boolean, allow_nil?: false, default: false, public?: true
    attribute :published_on, :date, public?: true
    attribute :price, :decimal, public?: true
    attribute :published_at, :utc_datetime_usec, public?: true

    attribute :status, :atom,
      allow_nil?: false,
      default: :draft,
      constraints: [one_of: [:draft, :live]],
      public?: true

    attribute :organization, :string, allow_nil?: false, public?: true
    attribute :author_name, :string, public?: true
    create_timestamp :inserted_at, public?: true
  end

  calculations do
    calculate :title_length, :integer, expr(string_length(title)), public?: true
    calculate :slow_mark, :string, AshGrpc.TestSupport.SlowMark, public?: true
  end
end

defmodule AshGrpc.TestSupport.SlowMark do
  @moduledoc false
  use Ash.Resource.Calculation

  @impl true
  def calculate(records, _opts, context) do
    if match?(%{name: "sleepy-load"}, context.actor), do: Process.sleep(1_000)
    Enum.map(records, & &1.title)
  end
end
