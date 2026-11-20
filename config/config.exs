import Config

config :ash,
  read_action_after_action_hooks_in_order?: true,
  default_string_length_count: :codepoints,
  policies: [no_filter_static_forbidden_reads?: false]

if config_env() == :test do
  config :logger, level: :warning
end
