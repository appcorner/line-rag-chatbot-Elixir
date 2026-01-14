defmodule ChatServiceWeb.MetricsController do
  use ChatServiceWeb, :controller

  def index(conn, _params) do
    metrics = ChatService.Telemetry.get_metrics()
    circuit_breakers = ChatService.CircuitBreaker.get_all_states()

    json(conn, %{
      service: "chat_service",
      version: Application.spec(:chat_service, :vsn) |> to_string(),
      uptime_seconds: ChatService.Telemetry.uptime_seconds(),
      messages_received: metrics.messages_received,
      messages_processed: metrics.messages_processed,
      errors: metrics.errors,
      active_buffers: count_active_buffers(),
      circuit_breakers: circuit_breakers,
      system: %{
        processes: :erlang.system_info(:process_count),
        memory_mb: Float.round(:erlang.memory(:total) / 1024 / 1024, 2),
        schedulers: :erlang.system_info(:schedulers_online)
      }
    })
  end

  defp count_active_buffers do
    DynamicSupervisor.count_children(ChatService.BufferSupervisor)[:active] || 0
  end
end
