defmodule AshGrpc.Examples.SupportTicket do
  @moduledoc false

  use Ash.Resource,
    domain: AshGrpc.Examples.SupportDesk,
    data_layer: Ash.DataLayer.Ets

  ets do
    table(:support_tickets)
  end

  actions do
    defaults([:read])

    create :create do
      accept([:subject, :body])
      primary?(true)
    end

    update :close do
      change(set_attribute(:status, :closed))
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :subject, :string do
      allow_nil?(false)
      public?(true)
      constraints(max_length: 200)
    end

    attribute :body, :string do
      allow_nil?(false)
      public?(true)
      constraints(max_length: 5_000)
    end

    attribute :status, :atom do
      allow_nil?(false)
      default(:open)
      public?(true)
    end
  end
end
