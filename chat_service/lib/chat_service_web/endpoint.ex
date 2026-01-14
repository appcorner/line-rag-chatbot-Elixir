defmodule ChatServiceWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :chat_service

  @session_options [
    store: :cookie,
    key: "_chat_service_key",
    signing_salt: "chat_svc_signing",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  socket "/socket", ChatServiceWeb.UserSocket,
    websocket: [timeout: 45_000],
    longpoll: false

  plug Plug.Static,
    at: "/",
    from: :chat_service,
    gzip: false,
    only: ChatServiceWeb.static_paths()

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    body_reader: {ChatServiceWeb.BodyReader, :read_body, []}

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options

  plug CORSPlug, origin: ["http://localhost:5173", "http://localhost:3000", "http://127.0.0.1:5173"]

  plug ChatServiceWeb.Router
end
