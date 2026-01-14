import Config

config :chat_service, ChatServiceWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  force_ssl: false

config :chat_service,
  port: String.to_integer(System.get_env("PORT") || "8888"),
  backend_url: System.get_env("BACKEND_URL") || "http://backend:8000"

config :logger, level: :info
