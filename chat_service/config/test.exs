import Config

config :chat_service, ChatServiceWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base_that_should_be_at_least_64_bytes_long_for_testing_purposes",
  server: false

config :chat_service,
  port: 8889,
  backend_url: "http://localhost:8000"

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
config :phoenix_live_view, :enable_expensive_runtime_checks, true
