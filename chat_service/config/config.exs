import Config

config :chat_service,
  ecto_repos: [ChatService.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true],
  port: 8888,
  backend_url: "http://localhost:8000",
  rate_limits: %{
    chat: {60_000, 20},
    webhook: {60_000, 100},
    api: {60_000, 60},
    llm: {60_000, 10}
  }

config :chat_service, ChatServiceWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ChatServiceWeb.ErrorHTML, json: ChatServiceWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ChatService.PubSub,
  live_view: [signing_salt: "cht_svc_salt"]

config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60, cleanup_interval_ms: 60_000 * 10]}

config :esbuild,
  version: "0.17.11",
  chat_service: [
    args: ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :tailwind,
  version: "3.4.3",
  chat_service: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :channel_id, :user_id]

config :phoenix, :json_library, Jason

# RabbitMQ configuration for high-throughput (millions/day)
config :chat_service, :rabbitmq,
  host: System.get_env("RABBITMQ_HOST", "localhost"),
  port: String.to_integer(System.get_env("RABBITMQ_PORT", "5672")),
  username: System.get_env("RABBITMQ_USER", "guest"),
  password: System.get_env("RABBITMQ_PASS", "guest"),
  virtual_host: System.get_env("RABBITMQ_VHOST", "/")

# Message queue mode: :oban (PostgreSQL) or :rabbitmq (RabbitMQ)
# Use :oban for <100k/day, :rabbitmq for millions
config :chat_service, :queue_mode, :rabbitmq

# Oban job queue configuration
config :chat_service, Oban,
  repo: ChatService.Repo,
  plugins: [
    # Prune completed jobs after 7 days
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    # Rescue stuck jobs after 30 minutes
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)}
  ],
  queues: [
    # High priority for webhook events (fast, immediate)
    webhook: 50,
    # Message processing queue
    messages: 20,
    # Background tasks (user profile fetch, etc.)
    background: 10
  ]

import_config "#{config_env()}.exs"
