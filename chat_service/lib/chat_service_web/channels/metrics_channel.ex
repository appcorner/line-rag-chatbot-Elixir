defmodule ChatServiceWeb.MetricsChannel do
  use ChatServiceWeb, :channel

  @impl true
  def join("metrics:live", _params, socket) do
    if connected?(socket), do: schedule_metrics_push()
    {:ok, socket}
  end

  @impl true
  def handle_info(:push_metrics, socket) do
    metrics = get_current_metrics()
    push(socket, "metrics_update", metrics)
    schedule_metrics_push()
    {:noreply, socket}
  end

  defp schedule_metrics_push do
    Process.send_after(self(), :push_metrics, 1000)
  end

  defp get_current_metrics do
    metrics = ChatService.Telemetry.get_metrics()
    %{
      messages_received: metrics.messages_received,
      messages_processed: metrics.messages_processed,
      errors: metrics.errors,
      active_buffers: DynamicSupervisor.count_children(ChatService.BufferSupervisor)[:active] || 0,
      memory_mb: Float.round(:erlang.memory(:total) / 1024 / 1024, 2),
      processes: :erlang.system_info(:process_count),
      uptime_seconds: ChatService.Telemetry.uptime_seconds(),
      circuit_breakers: ChatService.CircuitBreaker.get_all_states(),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp connected?(socket) do
    Phoenix.Socket.connected?(socket)
  rescue
    _ -> true
  end
end
