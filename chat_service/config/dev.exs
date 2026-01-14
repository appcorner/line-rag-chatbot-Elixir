import Config

# Database configuration
config :chat_service, ChatService.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "chat_service_dev",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :chat_service, ChatServiceWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 8888],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "dev_secret_key_base_that_should_be_at_least_64_bytes_long_for_security_purposes",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:chat_service, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:chat_service, ~w(--watch)]}
  ]

config :chat_service, ChatServiceWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/chat_service_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :chat_service,
  port: 8888,
  backend_url: "http://localhost:8000",
  vector_service_url: "localhost:50052"

config :logger, level: :debug
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
config :phoenix_live_view, :debug_heex_annotations, true
