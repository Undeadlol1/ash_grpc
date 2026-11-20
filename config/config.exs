import Config

config :ash,
  read_action_after_action_hooks_in_order?: true,
  default_string_length_count: :codepoints

config :logger, level: :none
