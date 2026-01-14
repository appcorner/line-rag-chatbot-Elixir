defmodule ChatServiceWeb.TrafficChannel do
  use ChatServiceWeb, :channel

  @impl true
  def join("traffic:live", _params, socket) do
    if connected?(socket), do: schedule_traffic_push()
    {:ok, assign(socket, :traffic_history, [])}
  end

  @impl true
  def handle_info(:push_traffic, socket) do
    traffic = get_current_traffic()
    history = update_history(socket.assigns.traffic_history, traffic)

    push(socket, "traffic_update", %{
      current: traffic,
      history: history
    })

    schedule_traffic_push()
    {:noreply, assign(socket, :traffic_history, history)}
  end

  defp schedule_traffic_push do
    Process.send_after(self(), :push_traffic, 2000)
  end

  defp get_current_traffic do
    metrics = ChatService.Telemetry.get_metrics()
    %{
      requests_per_second: metrics.messages_received / max(ChatService.Telemetry.uptime_seconds(), 1),
      active_connections: count_active_connections(),
      avg_response_ms: 45,
      error_rate: safe_error_rate(metrics),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp safe_error_rate(%{errors: errors, messages_processed: processed}) when processed > 0 do
    Float.round(errors / processed * 100, 2)
  end
  defp safe_error_rate(_), do: 0.0

  defp count_active_connections do
    case Registry.count(ChatService.BufferRegistry) do
      count when is_integer(count) -> count
      _ -> 0
    end
  end

  defp update_history(history, traffic) do
    (history ++ [traffic])
    |> Enum.take(-60)
  end

  defp connected?(socket) do
    Phoenix.Socket.connected?(socket)
  rescue
    _ -> true
  end
end
