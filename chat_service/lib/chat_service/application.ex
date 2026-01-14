defmodule ChatService.Application do
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    # Base children - always started
    base_children = [
      ChatService.Repo,
      {Oban, Application.fetch_env!(:chat_service, Oban)},
      ChatServiceWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:chat_service, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ChatService.PubSub},
      ChatService.AdminPresence,
      {Finch, name: ChatService.Finch, pools: finch_pools()},
      {Task.Supervisor, name: ChatService.TaskSupervisor},
      {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60 * 2, cleanup_interval_ms: 60_000 * 10]},
      ChatService.CircuitBreaker.Supervisor,
      {Registry, keys: :unique, name: ChatService.BufferRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: ChatService.BufferSupervisor},
      ChatService.Telemetry,
      ChatService.Agents.Supervisor,
      ChatService.GracefulShutdown,
      ChatServiceWeb.Endpoint
    ]

    # Add Broadway pipeline if RabbitMQ mode is enabled and available
    children = case Application.get_env(:chat_service, :queue_mode, :oban) do
      :rabbitmq ->
        if rabbitmq_available?() do
          Logger.info("Starting with RabbitMQ mode (high throughput - millions/day)")
          base_children ++ [ChatService.Pipelines.WebhookPipeline]
        else
          Logger.warning("RabbitMQ not available, falling back to Oban mode")
          Application.put_env(:chat_service, :queue_mode, :oban)
          base_children
        end
      _ ->
        Logger.info("Starting with Oban mode (PostgreSQL queue)")
        base_children
    end

    opts = [strategy: :one_for_one, name: ChatService.Supervisor]

    Logger.info("Starting Chat Service with Phoenix")

    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    ChatServiceWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  @impl true
  def stop(_state) do
    Logger.info("Stopping Chat Service")
    ChatService.GracefulShutdown.shutdown()
    :ok
  end

  defp finch_pools do
    %{
      :default => [size: 50, count: 4, conn_opts: [transport_opts: [timeout: 30_000]]],
      "https://api.line.me" => [size: 50, count: 4, protocols: [:http2], conn_opts: [transport_opts: [timeout: 15_000]]],
      "https://generativelanguage.googleapis.com" => [size: 25, count: 4, conn_opts: [transport_opts: [timeout: 60_000]]],
      "https://api.openai.com" => [size: 25, count: 4, conn_opts: [transport_opts: [timeout: 60_000]]],
      backend_url() => [size: 50, count: 4]
    }
  end

  defp backend_url do
    Application.get_env(:chat_service, :backend_url, "http://localhost:8000")
  end

  defp rabbitmq_available? do
    config = Application.get_env(:chat_service, :rabbitmq, [])
    host = Keyword.get(config, :host, "localhost")
    port = Keyword.get(config, :port, 5672)

    case :gen_tcp.connect(String.to_charlist(host), port, [], 2000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true
      {:error, _} ->
        false
    end
  end
end
