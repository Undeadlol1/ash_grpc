spark_locals_without_parens = [
  action: 1,
  args: 1,
  bulk?: 1,
  clear_fields: 1,
  deprecated: 1,
  fields: 1,
  filter: 1,
  hide_fields: 1,
  load: 1,
  max_bulk_size: 1,
  max_stream_failures: 1,
  package: 1,
  page: 1,
  proto_message: 1,
  read_action: 1,
  reserved: 1,
  resource: 1,
  resource: 2,
  rpc: 1,
  rpc: 2,
  rpc: 3,
  rpc: 4,
  service: 1,
  service: 2,
  sort: 1,
  streaming: 1,
  subscription: 1,
  subscription: 2,
  subscription: 3,
  subscription: 4
]

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  import_deps: [:ash, :spark],
  locals_without_parens: spark_locals_without_parens,
  export: [locals_without_parens: spark_locals_without_parens]
]
