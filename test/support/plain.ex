defmodule AshGrpc.TestSupport.Plain do
  @moduledoc false
  use Ash.Resource,
    domain: nil,
    data_layer: Ash.DataLayer.Ets,
    validate_domain_inclusion?: false

  actions do
    defaults [:read]
  end

  attributes do
    uuid_primary_key :id
  end
end
