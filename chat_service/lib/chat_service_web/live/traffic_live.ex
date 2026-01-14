defmodule ChatServiceWeb.TrafficLive do
  use ChatServiceWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(1000, self(), :update_traffic)
    end

    {:ok,
     socket
     |> assign(:page_title, "Traffic Monitor")
     |> assign(:traffic, get_traffic())
     |> assign(:history, [])
     |> assign(:services, get_services_status())}
  end

  @impl true
  def handle_info(:update_traffic, socket) do
    traffic = get_traffic()
    history = update_history(socket.assigns.history, traffic)

    {:noreply,
     socket
     |> assign(:traffic, traffic)
     |> assign(:history, history)
     |> assign(:services, get_services_status())}
  end

  defp get_traffic do
    metrics = ChatService.Telemetry.get_metrics()

    # Get real-time RPS from sliding window
    rps = ChatService.Telemetry.get_rps(5)  # Average over last 5 seconds

    # Get real average response time
    avg_response = ChatService.Telemetry.get_avg_response_time()

    # Get active connections (WebSocket + buffers)
    ws_connections = ChatService.Telemetry.get_active_connections()
    buffer_count = DynamicSupervisor.count_children(ChatService.BufferSupervisor)[:active] || 0

    %{
      requests_per_second: rps,
      active_connections: ws_connections + buffer_count,
      avg_response_ms: avg_response,
      error_rate: safe_error_rate(metrics),
      total_requests: metrics.messages_received,
      total_processed: metrics.messages_processed,
      active_ws: ws_connections,
      active_buffers: buffer_count
    }
  end

  defp safe_error_rate(%{errors: errors, messages_processed: processed}) when processed > 0 do
    Float.round(errors / processed * 100, 2)
  end
  defp safe_error_rate(_), do: 0.0

  defp get_services_status do
    %{
      phoenix: check_phoenix(),
      database: check_database(),
      vector_service: check_vector_service(),
      oban: check_oban(),
      pubsub: check_pubsub()
    }
  end

  defp check_phoenix do
    %{status: :online, latency: 0}
  end

  defp check_oban do
    try do
      case Oban.check_queue(:default) do
        %{paused: false} -> %{status: :online, latency: 0}
        _ -> %{status: :offline, latency: 0}
      end
    rescue
      _ -> %{status: :online, latency: 0}
    end
  end

  defp check_pubsub do
    try do
      Phoenix.PubSub.subscribe(ChatService.PubSub, "health_check_#{:rand.uniform(100000)}")
      %{status: :online, latency: 0}
    rescue
      _ -> %{status: :offline, latency: 0}
    end
  end

  defp check_vector_service do
    start = System.monotonic_time(:millisecond)
    case ChatService.VectorService.Client.health() do
      {:ok, _} ->
        %{status: :online, latency: System.monotonic_time(:millisecond) - start}
      _ ->
        %{status: :offline, latency: 0}
    end
  end

  defp check_database do
    start = System.monotonic_time(:millisecond)
    case ChatService.Repo.query("SELECT 1") do
      {:ok, _} ->
        %{status: :online, latency: System.monotonic_time(:millisecond) - start}
      _ ->
        %{status: :offline, latency: 0}
    end
  end

  defp update_history(history, traffic) do
    entry = %{
      timestamp: DateTime.utc_now(),
      rps: traffic.requests_per_second,
      error_rate: traffic.error_rate
    }
    (history ++ [entry]) |> Enum.take(-30)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex justify-between items-center">
        <h1 class="text-2xl font-bold">Traffic Monitor</h1>
        <div class="text-sm text-gray-400">
          Real-time updates every 1s
        </div>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
        <div class="bg-gradient-to-br from-purple-500/10 to-purple-600/10 border border-purple-500/30 rounded-xl p-6">
          <p class="text-gray-400 text-sm">Requests/Second (5s avg)</p>
          <p class="text-3xl font-bold text-white mt-1"><%= @traffic.requests_per_second %></p>
        </div>
        <div class="bg-gradient-to-br from-blue-500/10 to-blue-600/10 border border-blue-500/30 rounded-xl p-6">
          <p class="text-gray-400 text-sm">Active Connections</p>
          <p class="text-3xl font-bold text-white mt-1"><%= @traffic.active_connections %></p>
          <p class="text-xs text-gray-500 mt-1">WS: <%= @traffic.active_ws %> | Buffers: <%= @traffic.active_buffers %></p>
        </div>
        <div class="bg-gradient-to-br from-green-500/10 to-green-600/10 border border-green-500/30 rounded-xl p-6">
          <p class="text-gray-400 text-sm">Avg Response (60s)</p>
          <p class="text-3xl font-bold text-white mt-1"><%= @traffic.avg_response_ms %> ms</p>
        </div>
        <div class="bg-gradient-to-br from-red-500/10 to-red-600/10 border border-red-500/30 rounded-xl p-6">
          <p class="text-gray-400 text-sm">Error Rate</p>
          <p class="text-3xl font-bold text-white mt-1"><%= @traffic.error_rate %>%</p>
        </div>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <div class="bg-gray-800 rounded-xl p-6 border border-gray-700">
          <h2 class="text-lg font-semibold mb-4">Services Status</h2>
          <div class="space-y-3">
            <%= for {name, info} <- @services do %>
              <div class="flex items-center justify-between p-4 bg-gray-700/50 rounded-lg">
                <div class="flex items-center gap-3">
                  <div class={[
                    "w-3 h-3 rounded-full",
                    info.status == :online && "bg-green-500 animate-pulse",
                    info.status == :offline && "bg-red-500"
                  ]}></div>
                  <span class="capitalize"><%= String.replace(to_string(name), "_", " ") %></span>
                </div>
                <div class="flex items-center gap-4">
                  <span class="text-gray-400 text-sm"><%= info.latency %>ms</span>
                  <span class={[
                    "px-2 py-1 rounded text-xs font-semibold",
                    info.status == :online && "bg-green-500/20 text-green-400",
                    info.status == :offline && "bg-red-500/20 text-red-400"
                  ]}>
                    <%= String.upcase(to_string(info.status)) %>
                  </span>
                </div>
              </div>
            <% end %>
          </div>
        </div>

        <div class="bg-gray-800 rounded-xl p-6 border border-gray-700">
          <h2 class="text-lg font-semibold mb-4">Traffic History (30s)</h2>
          <div class="h-48 flex items-end gap-1">
            <%= for entry <- @history do %>
              <div
                class="flex-1 bg-purple-500/50 rounded-t transition-all duration-300"
                style={"height: #{min(entry.rps * 10, 100)}%"}
                title={"#{entry.rps} req/s"}
              ></div>
            <% end %>
            <%= if length(@history) < 30 do %>
              <%= for _ <- 1..(30 - length(@history)) do %>
                <div class="flex-1 bg-gray-700 rounded-t h-1"></div>
              <% end %>
            <% end %>
          </div>
          <div class="flex justify-between mt-2 text-xs text-gray-500">
            <span>30s ago</span>
            <span>Now</span>
          </div>
        </div>
      </div>

      <div class="bg-gray-800 rounded-xl p-6 border border-gray-700">
        <h2 class="text-lg font-semibold mb-4">Traffic Summary</h2>
        <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
          <div class="p-4 bg-gray-700/50 rounded-lg">
            <p class="text-gray-400 text-sm">Total Requests</p>
            <p class="text-xl font-bold text-white"><%= format_number(@traffic.total_requests) %></p>
          </div>
          <div class="p-4 bg-gray-700/50 rounded-lg">
            <p class="text-gray-400 text-sm">Total Processed</p>
            <p class="text-xl font-bold text-white"><%= format_number(@traffic.total_processed) %></p>
          </div>
          <div class="p-4 bg-gray-700/50 rounded-lg">
            <p class="text-gray-400 text-sm">Success Rate</p>
            <p class="text-xl font-bold text-green-400"><%= 100 - @traffic.error_rate %>%</p>
          </div>
          <div class="p-4 bg-gray-700/50 rounded-lg">
            <p class="text-gray-400 text-sm">Peak RPS</p>
            <p class="text-xl font-bold text-white"><%= get_peak_rps(@history) %></p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_number(num) when num >= 1_000_000, do: "#{Float.round(num / 1_000_000, 1)}M"
  defp format_number(num) when num >= 1_000, do: "#{Float.round(num / 1_000, 1)}K"
  defp format_number(num), do: to_string(num)

  defp get_peak_rps([]), do: 0
  defp get_peak_rps(history) do
    history
    |> Enum.map(& &1.rps)
    |> Enum.max()
    |> Float.round(2)
  end
end
