defmodule ChatServiceWeb.Router do
  use ChatServiceWeb, :router

  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ChatServiceWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :webhook do
    plug :accepts, ["json"]
    plug ChatServiceWeb.Plugs.RateLimit, bucket: :webhook
  end

  scope "/", ChatServiceWeb do
    pipe_through :browser

    get "/", PageController, :home

    live "/dashboard", DashboardLive, :index
    live "/traffic", TrafficLive, :index
    live "/channels", ChannelsLive, :index
    live "/channels/:id", ChannelSettingsLive, :show
    live "/conversations", ConversationsLive, :index
    live "/conversations/:id", ConversationsLive, :show
    live "/datasets", DatasetsLive, :index
    live "/datasets/:id", DatasetDetailLive, :show
    live "/llm", LlmLive, :index
    live "/llm-test", LlmTestLive, :index
    live "/agents", AgentsLive, :index
    live "/settings", SettingsLive, :index
  end

  scope "/webhook", ChatServiceWeb do
    pipe_through :webhook
    post "/:channel_id", WebhookController, :handle
  end

  scope "/api", ChatServiceWeb do
    pipe_through :api

    scope "/webhook" do
      pipe_through :webhook
      post "/:channel_id", WebhookController, :handle
    end

    get "/health", HealthController, :check
    get "/metrics", MetricsController, :index

    scope "/agents" do
      get "/skills", AgentsController, :skills
      resources "/", AgentsController, only: [:index, :create, :show]
      post "/:id/chat", AgentsController, :chat
      get "/:id/stream", AgentsController, :stream
    end

    scope "/dashboard" do
      get "/stats", DashboardController, :stats
      get "/recent-activity", DashboardController, :recent_activity
      get "/system-status", DashboardController, :system_status
    end

    get "/stats", DashboardController, :stats

    resources "/line-oas", LineOaController, except: [:new, :edit]

    scope "/conversations" do
      resources "/", ConversationsController, only: [:index, :show, :delete]
      get "/:conversation_id/messages", ConversationsController, :messages
      post "/:conversation_id/messages", ConversationsController, :create_message
    end

    scope "/admin" do
      post "/login", AdminController, :login
      post "/register", AdminController, :register
      get "/me", AdminController, :me
      put "/me", AdminController, :update_me
      post "/me/avatar", AdminController, :upload_avatar
      post "/me/password", AdminController, :change_password
    end

    scope "/datasets" do
      resources "/", DatasetsController, except: [:new, :edit]
      post "/:id/documents", DatasetsController, :add_document
      post "/:id/search", DatasetsController, :search_documents
    end

    scope "/llm" do
      get "/providers", LlmController, :providers
      get "/providers/:provider/models", LlmController, :models
      post "/providers/:provider/models", LlmController, :models
      get "/providers/:provider/embedding-models", LlmController, :embedding_models
      post "/chat", LlmController, :chat
      post "/embed", LlmController, :embed
    end
  end

  scope "/" do
    pipe_through :browser

    live_dashboard "/live-dashboard",
      metrics: ChatServiceWeb.Telemetry,
      ecto_repos: [ChatService.Repo],
      additional_pages: [
        services: ChatServiceWeb.ServicesPage
      ]
  end
end
