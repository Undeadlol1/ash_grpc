defmodule AshGrpc.TestSupport.Dimensions do
  @moduledoc false
  use Ash.TypedStruct

  typed_struct do
    field :width, :integer, allow_nil?: false
    field :height, :integer
  end
end

defmodule AshGrpc.TestSupport.Label do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded, extensions: [AshGrpc.Resource]

  grpc do
    proto_message "Label"
    fields text: 1, color: 2, size: 4
    reserved [3]
    deprecated [:color]
  end

  attributes do
    attribute :text, :string, allow_nil?: false, public?: true
    attribute :color, :string, public?: true
    attribute :size, AshGrpc.TestSupport.Dimensions, public?: true
  end
end

defmodule AshGrpc.TestSupport.Parcel do
  @moduledoc false
  use Ash.Resource,
    domain: AshGrpc.TestSupport.Parcels,
    data_layer: Ash.DataLayer.Ets,
    simple_notifiers: [AshGrpc.Notifier],
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGrpc.Resource]

  alias AshGrpc.TestSupport.Dimensions
  alias AshGrpc.TestSupport.Label

  @scalars [:photo, :pickup, :pickup_usec, :transit, :packed_at, :shipped_at, :token]
  @arrays [:tags, :moods, :scores, :stamps, :tiers, :blobs, :days]
  @nested [:dimensions, :label, :labels, :extents, :handling, :weight, :sticker, :seal]

  field_policies do
    field_policy :seal do
      forbid_if actor_attribute_equals(:name, "hush-seal")
      authorize_if always()
    end

    field_policy :* do
      authorize_if always()
    end
  end

  grpc do
    proto_message "Parcel"

    fields id: 1,
           photo: 2,
           pickup: 3,
           pickup_usec: 4,
           transit: 5,
           packed_at: 6,
           shipped_at: 7,
           token: 8,
           tags: 9,
           moods: 10,
           scores: 11,
           stamps: 12,
           tiers: 13,
           blobs: 14,
           days: 15,
           dimensions: 16,
           label: 17,
           labels: 18,
           extents: 19,
           handling: 20,
           weight: 21,
           sticker: 22,
           seal: 23
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept @scalars ++ @arrays ++ @nested
    end

    update :update do
      primary? true
      accept @arrays ++ [:label, :dimensions]
    end

    create :pack do
      argument :blob, :binary
      argument :at, :time
      argument :lasts, :duration
      argument :labels, {:array, :string}
      argument :box, :map, constraints: [fields: [grams: [type: :integer]]]
      change set_attribute(:weight, arg(:box))
      change set_attribute(:tags, arg(:labels))
      change set_attribute(:photo, arg(:blob))
      change set_attribute(:pickup, arg(:at))
      change set_attribute(:transit, arg(:lasts))
    end
  end

  policies do
    policy always() do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :photo, :binary, public?: true
    attribute :pickup, :time, public?: true
    attribute :pickup_usec, :time_usec, public?: true
    attribute :transit, :duration, public?: true
    attribute :packed_at, :naive_datetime, public?: true
    attribute :shipped_at, :datetime, public?: true
    attribute :token, :url_encoded_binary, public?: true
    attribute :tags, {:array, :string}, public?: true
    attribute :moods, {:array, AshGrpc.TestSupport.Mood}, public?: true
    attribute :scores, {:array, :integer}, allow_nil?: false, default: [], public?: true
    attribute :stamps, {:array, :utc_datetime_usec}, public?: true
    attribute :tiers, {:array, AshGrpc.TestSupport.Tier}, public?: true
    attribute :blobs, {:array, :map}, public?: true
    attribute :days, {:array, :date}, public?: true
    attribute :dimensions, Dimensions, public?: true
    attribute :label, Label, public?: true
    attribute :labels, {:array, Label}, public?: true
    attribute :extents, {:array, Dimensions}, public?: true

    attribute :handling, :keyword,
      constraints: [fields: [fragile: [type: :boolean], note: [type: :string]]],
      public?: true

    attribute :weight, :map,
      constraints: [fields: [grams: [type: :integer, allow_nil?: false]]],
      public?: true

    attribute :sticker, :struct, constraints: [instance_of: Label], public?: true
    attribute :seal, Label, public?: true
  end
end

defmodule AshGrpc.TestSupport.Parcels do
  @moduledoc false
  use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

  alias AshGrpc.TestSupport.Parcel

  grpc do
    package "parcels.v1"

    service "Parcels" do
      rpc Parcel, :list_parcels, :read, sort: false, filter: false, page: false

      rpc Parcel, :create_parcel, :create,
        sort: false,
        filter: false,
        page: false,
        args: [
          photo: 1,
          pickup: 2,
          pickup_usec: 3,
          transit: 4,
          packed_at: 5,
          shipped_at: 6,
          token: 7,
          tags: 8,
          moods: 9,
          scores: 10,
          stamps: 11,
          tiers: 12,
          blobs: 13,
          days: 14,
          dimensions: 15,
          label: 16,
          labels: 17,
          extents: 18,
          handling: 19,
          weight: 20,
          sticker: 21,
          seal: 22
        ]

      rpc Parcel, :update_parcel, :update,
        sort: false,
        filter: false,
        page: false,
        args: [id: 1, tags: 2, moods: 3, scores: 4, label: 6, dimensions: 7],
        clear_fields: 5

      rpc Parcel, :pack_parcel, :pack,
        args: [blob: 1, at: 2, lasts: 3, labels: 4, box: 5],
        sort: false,
        filter: false,
        page: false

      subscription Parcel, :watch_parcels, :read, sort: false, filter: false
    end
  end

  resources do
    resource Parcel
  end
end

defmodule AshGrpc.TestSupport.ParcelsEndpoint do
  @moduledoc false
  use AshGrpc.Endpoint,
    domains: [AshGrpc.TestSupport.Parcels],
    authenticator: AshGrpc.TestSupport.Authenticator
end
