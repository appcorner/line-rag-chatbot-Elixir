defmodule ChatServiceWeb.DashboardLive do
  use ChatServiceWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(2000, self(), :update_metrics)
    end

    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:metrics, get_metrics())
     |> assign(:circuit_breakers, ChatService.CircuitBreaker.get_all_states())}
  end

  @impl true
  def handle_info(:update_metrics, socket) do
    {:noreply,
     socket
     |> assign(:metrics, get_metrics())
     |> assign(:circuit_breakers, ChatService.CircuitBreaker.get_all_states())}
  end

  defp get_metrics do
    telemetry_metrics = ChatService.Telemetry.get_metrics()
    %{
      messages_received: telemetry_metrics.messages_received,
      messages_processed: telemetry_metrics.messages_processed,
      errors: telemetry_metrics.errors,
      active_buffers: DynamicSupervisor.count_children(ChatService.BufferSupervisor)[:active] || 0,
      uptime_seconds: ChatService.Telemetry.uptime_seconds(),
      memory_mb: Float.round(:erlang.memory(:total) / 1024 / 1024, 2),
      processes: :erlang.system_info(:process_count),
      schedulers: :erlang.system_info(:schedulers_online)
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex justify-between items-center">
        <h1 class="text-2xl font-bold">Dashboard</h1>
        <div class="flex items-center gap-2 text-sm text-gray-400">
          <div class="w-2 h-2 bg-green-500 rounded-full animate-pulse"></div>
          Uptime: <%= format_uptime(@metrics.uptime_seconds) %>
        </div>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
        <div class="bg-gradient-to-br from-green-500/10 to-green-600/10 border border-green-500/30 rounded-xl p-6">
          <p class="text-gray-400 text-sm">Messages Received</p>
          <p class="text-3xl font-bold text-white mt-1"><%= format_number(@metrics.messages_received) %></p>
        </div>
        <div class="bg-gradient-to-br from-blue-500/10 to-blue-600/10 border border-blue-500/30 rounded-xl p-6">
          <p class="text-gray-400 text-sm">Messages Processed</p>
          <p class="text-3xl font-bold text-white mt-1"><%= format_number(@metrics.messages_processed) %></p>
        </div>
        <div class="bg-gradient-to-br from-orange-500/10 to-orange-600/10 border border-orange-500/30 rounded-xl p-6">
          <p class="text-gray-400 text-sm">Active Buffers</p>
          <p class="text-3xl font-bold text-white mt-1"><%= @metrics.active_buffers %></p>
        </div>
        <div class="bg-gradient-to-br from-red-500/10 to-red-600/10 border border-red-500/30 rounded-xl p-6">
          <p class="text-gray-400 text-sm">Errors</p>
          <p class="text-3xl font-bold text-white mt-1"><%= @metrics.errors %></p>
        </div>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <div class="bg-gray-800 rounded-xl p-6 border border-gray-700">
          <h2 class="text-lg font-semibold mb-4">Circuit Breakers</h2>
          <div class="space-y-3">
            <%= for {name, status} <- @circuit_breakers do %>
              <div class="flex items-center justify-between p-3 bg-gray-700/50 rounded-lg">
                <span class="capitalize"><%= String.replace(to_string(name), "_", " ") %></span>
                <span class={[
                  "px-2 py-1 rounded text-xs font-semibold",
                  to_string(status) == "closed" && "bg-green-500/20 text-green-400",
                  to_string(status) == "half_open" && "bg-yellow-500/20 text-yellow-400",
                  to_string(status) == "open" && "bg-red-500/20 text-red-400"
                ]}>
                  <%= String.upcase(to_string(status)) %>
                </span>
              </div>
            <% end %>
          </div>
        </div>

        <div class="bg-gray-800 rounded-xl p-6 border border-gray-700">
          <h2 class="text-lg font-semibold mb-4">System Resources</h2>
          <div class="space-y-4">
            <div>
              <div class="flex justify-between mb-1">
                <span class="text-gray-400">Memory</span>
                <span class="text-white"><%= @metrics.memory_mb %> MB</span>
              </div>
              <div class="h-2 bg-gray-700 rounded-full overflow-hidden">
                <div class="h-full bg-blue-500" style={"width: #{min(@metrics.memory_mb / 1024 * 100, 100)}%"}></div>
              </div>
            </div>
            <div>
              <div class="flex justify-between mb-1">
                <span class="text-gray-400">Processes</span>
                <span class="text-white"><%= format_number(@metrics.processes) %></span>
              </div>
              <div class="h-2 bg-gray-700 rounded-full overflow-hidden">
                <div class="h-full bg-purple-500" style={"width: #{@metrics.processes / 262144 * 100}%"}></div>
              </div>
            </div>
            <div class="flex justify-between p-3 bg-gray-700/50 rounded-lg">
              <span class="text-gray-400">Schedulers Online</span>
              <span class="text-white"><%= @metrics.schedulers %></span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_uptime(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_uptime(seconds) when seconds < 3600 do
    "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  end
  defp format_uptime(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    "#{hours}h #{minutes}m"
  end

  defp format_number(num) when num >= 1_000_000, do: "#{Float.round(num / 1_000_000, 1)}M"
  defp format_number(num) when num >= 1_000, do: "#{Float.round(num / 1_000, 1)}K"
  defp format_number(num), do: to_string(num)
end
