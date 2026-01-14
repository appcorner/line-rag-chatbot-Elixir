defmodule ChatServiceWeb.ServicesPage do
  @moduledoc """
  Custom Phoenix LiveDashboard page for monitoring all services.
  Uses LiveDashboard PageBuilder components for consistent UI.
  """
  use Phoenix.LiveDashboard.PageBuilder

  @impl true
  def menu_link(_, _) do
    {:ok, "Services"}
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(3000, self(), :refresh)
    end

    {:ok, assign(socket,
      services: get_all_services(),
      system_info: get_system_info(),
      queue_stats: get_queue_stats()
    )}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign(socket,
      services: get_all_services(),
      system_info: get_system_info(),
      queue_stats: get_queue_stats()
    )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="phx-dashboard-page">
      <!-- System Overview Cards -->
      <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; margin-bottom: 24px;">
        <%= for service <- @services do %>
          <div style={"background: #{status_bg(service.status)}; border-radius: 8px; padding: 16px; border-left: 4px solid #{status_border(service.status)};"}>
            <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px;">
              <span style="font-weight: 600; font-size: 14px;"><%= service.name %></span>
              <span style={"background: #{status_badge_bg(service.status)}; color: white; padding: 2px 8px; border-radius: 12px; font-size: 11px; font-weight: 500;"}>
                <%= status_text(service.status) %>
              </span>
            </div>
            <div style="font-size: 12px; color: #6b7280;">
              <%= for {key, value} <- service.details do %>
                <div style="display: flex; justify-content: space-between; padding: 2px 0;">
                  <span><%= key %></span>
                  <span style="font-weight: 500; color: #374151;"><%= value %></span>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>

      <!-- System Metrics -->
      <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 16px; margin-bottom: 24px;">
        <!-- Memory Usage -->
        <div style="background: #1f2937; border-radius: 8px; padding: 16px;">
          <h3 style="font-size: 14px; font-weight: 600; margin-bottom: 12px; color: #f3f4f6;">Memory Usage</h3>
          <div style="margin-bottom: 8px;">
            <div style="display: flex; justify-content: space-between; font-size: 12px; margin-bottom: 4px;">
              <span style="color: #9ca3af;">Used</span>
              <span style="color: #f3f4f6;"><%= @system_info.memory_used_mb %> MB / <%= @system_info.memory_total_mb %> MB</span>
            </div>
            <div style="background: #374151; border-radius: 4px; height: 8px; overflow: hidden;">
              <div style={"background: linear-gradient(90deg, #10b981, #34d399); height: 100%; width: #{@system_info.memory_percent}%; transition: width 0.3s;"}></div>
            </div>
          </div>
          <div style="display: flex; justify-content: space-between; font-size: 11px; color: #6b7280;">
            <span>Processes: <%= @system_info.process_count %></span>
            <span>Atoms: <%= @system_info.atom_count %></span>
          </div>
        </div>

        <!-- Queue Statistics -->
        <div style="background: #1f2937; border-radius: 8px; padding: 16px;">
          <h3 style="font-size: 14px; font-weight: 600; margin-bottom: 12px; color: #f3f4f6;">Queue Statistics</h3>
          <%= for {queue_name, stats} <- @queue_stats do %>
            <div style="margin-bottom: 8px;">
              <div style="display: flex; justify-content: space-between; font-size: 12px; margin-bottom: 4px;">
                <span style="color: #9ca3af;"><%= queue_name %></span>
                <span style="color: #f3f4f6;"><%= stats.executing %>/<%= stats.limit %> active</span>
              </div>
              <div style="background: #374151; border-radius: 4px; height: 6px; overflow: hidden;">
                <div style={"background: #{queue_color(queue_name)}; height: 100%; width: #{queue_percent(stats)}%; transition: width 0.3s;"}></div>
              </div>
            </div>
          <% end %>
          <div style="display: flex; justify-content: space-between; font-size: 11px; color: #6b7280; margin-top: 8px;">
            <span>Pending: <%= @queue_stats |> Enum.map(fn {_, s} -> s.available end) |> Enum.sum() %></span>
            <span>Mode: <%= Application.get_env(:chat_service, :queue_mode, :oban) |> to_string() |> String.upcase() %></span>
          </div>
        </div>
      </div>

      <!-- Schedulers & I/O -->
      <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 16px;">
        <!-- Scheduler Utilization -->
        <div style="background: #1f2937; border-radius: 8px; padding: 16px;">
          <h3 style="font-size: 14px; font-weight: 600; margin-bottom: 12px; color: #f3f4f6;">Schedulers (<%= @system_info.scheduler_count %>)</h3>
          <div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(40px, 1fr)); gap: 4px;">
            <%= for i <- 1..@system_info.scheduler_count do %>
              <div style="background: #374151; border-radius: 4px; height: 24px; display: flex; align-items: center; justify-content: center; font-size: 10px; color: #9ca3af;">
                <%= i %>
              </div>
            <% end %>
          </div>
          <div style="display: flex; justify-content: space-between; font-size: 11px; color: #6b7280; margin-top: 8px;">
            <span>Online: <%= @system_info.scheduler_count %></span>
            <span>Dirty CPU: <%= @system_info.dirty_cpu_schedulers %></span>
            <span>Dirty I/O: <%= @system_info.dirty_io_schedulers %></span>
          </div>
        </div>

        <!-- Connection Pool -->
        <div style="background: #1f2937; border-radius: 8px; padding: 16px;">
          <h3 style="font-size: 14px; font-weight: 600; margin-bottom: 12px; color: #f3f4f6;">Database Pool</h3>
          <div style="margin-bottom: 8px;">
            <div style="display: flex; justify-content: space-between; font-size: 12px; margin-bottom: 4px;">
              <span style="color: #9ca3af;">Connections</span>
              <span style="color: #f3f4f6;"><%= @system_info.db_pool_size %> configured</span>
            </div>
            <div style="display: grid; grid-template-columns: repeat(10, 1fr); gap: 2px;">
              <%= for _ <- 1..@system_info.db_pool_size do %>
                <div style="background: #10b981; border-radius: 2px; height: 16px;"></div>
              <% end %>
            </div>
          </div>
          <div style="font-size: 11px; color: #6b7280;">
            Host: <%= @system_info.db_host %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Status styling helpers
  defp status_bg(:online), do: "#064e3b20"
  defp status_bg(:degraded), do: "#78350f20"
  defp status_bg(:offline), do: "#7f1d1d20"
  defp status_bg(_), do: "#1f293720"

  defp status_border(:online), do: "#10b981"
  defp status_border(:degraded), do: "#f59e0b"
  defp status_border(:offline), do: "#ef4444"
  defp status_border(_), do: "#6b7280"

  defp status_badge_bg(:online), do: "#10b981"
  defp status_badge_bg(:degraded), do: "#f59e0b"
  defp status_badge_bg(:offline), do: "#ef4444"
  defp status_badge_bg(_), do: "#6b7280"

  defp status_text(:online), do: "ONLINE"
  defp status_text(:degraded), do: "DEGRADED"
  defp status_text(:offline), do: "OFFLINE"
  defp status_text(_), do: "UNKNOWN"

  defp queue_color("webhook"), do: "#3b82f6"
  defp queue_color("messages"), do: "#8b5cf6"
  defp queue_color("background"), do: "#6366f1"
  defp queue_color(_), do: "#6b7280"

  defp queue_percent(%{executing: exec, limit: limit}) when limit > 0, do: round(exec / limit * 100)
  defp queue_percent(_), do: 0

  # Data fetching functions
  defp get_system_info do
    memory = :erlang.memory()
    config = Application.get_env(:chat_service, ChatService.Repo, [])

    %{
      memory_total_mb: round(:erlang.memory(:total) / 1_048_576),
      memory_used_mb: round((memory[:total] - memory[:binary] - memory[:atom]) / 1_048_576),
      memory_percent: min(round(:erlang.memory(:total) / :erlang.memory(:system) * 100), 100),
      process_count: :erlang.system_info(:process_count),
      atom_count: :erlang.system_info(:atom_count),
      scheduler_count: :erlang.system_info(:schedulers_online),
      dirty_cpu_schedulers: :erlang.system_info(:dirty_cpu_schedulers_online),
      dirty_io_schedulers: :erlang.system_info(:dirty_io_schedulers),
      db_pool_size: Keyword.get(config, :pool_size, 10),
      db_host: Keyword.get(config, :hostname, "localhost")
    }
  end

  defp get_queue_stats do
    queues = Application.get_env(:chat_service, Oban)[:queues] || []

    Enum.map(queues, fn {name, limit} ->
      stats = try do
        case Oban.check_queue(queue: name) do
          %{} = info -> %{
            available: Map.get(info, :available, 0),
            executing: Map.get(info, :executing, 0),
            limit: limit
          }
          _ -> %{available: 0, executing: 0, limit: limit}
        end
      rescue
        _ -> %{available: 0, executing: 0, limit: limit}
      end
      {to_string(name), stats}
    end)
  end

  defp get_all_services do
    [
      get_postgresql_status(),
      get_pubsub_status(),
      get_rabbitmq_status(),
      get_oban_status(),
      get_broadway_status(),
      get_backend_status(),
      get_line_api_status()
    ]
  end

  defp get_postgresql_status do
    status = try do
      case Ecto.Adapters.SQL.query(ChatService.Repo, "SELECT 1", []) do
        {:ok, _} -> :online
        _ -> :offline
      end
    rescue
      _ -> :offline
    end

    config = Application.get_env(:chat_service, ChatService.Repo, [])

    %{
      name: "PostgreSQL",
      status: status,
      details: [
        {"Host", Keyword.get(config, :hostname, "localhost")},
        {"Database", Keyword.get(config, :database, "chat_service")},
        {"Pool Size", Keyword.get(config, :pool_size, 10)}
      ]
    }
  end

  defp get_pubsub_status do
    status = case Process.whereis(ChatService.PubSub) do
      nil -> :offline
      pid when is_pid(pid) -> :online
    end

    subscribers = try do
      Registry.count(ChatService.PubSub)
    rescue
      _ -> 0
    end

    %{
      name: "Phoenix.PubSub",
      status: status,
      details: [
        {"Adapter", "PG2 (Local)"},
        {"Subscribers", subscribers}
      ]
    }
  end

  defp get_rabbitmq_status do
    config = Application.get_env(:chat_service, :rabbitmq, [])
    host = Keyword.get(config, :host, "localhost")
    port = Keyword.get(config, :port, 5672)

    status = case :gen_tcp.connect(String.to_charlist(host), port, [], 2000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :online
      {:error, _} ->
        :offline
    end

    queue_mode = Application.get_env(:chat_service, :queue_mode, :oban)

    %{
      name: "RabbitMQ",
      status: status,
      details: [
        {"Host", "#{host}:#{port}"},
        {"Mode", if(queue_mode == :rabbitmq, do: "ACTIVE", else: "Standby")}
      ]
    }
  end

  defp get_oban_status do
    status = try do
      case Oban.check_queue(queue: :webhook) do
        %{paused: _} -> :online
        _ -> :online
      end
    rescue
      _ ->
        case Process.whereis(Oban.Registry) do
          nil -> :offline
          _pid -> :online
        end
    end

    queues = Application.get_env(:chat_service, Oban)[:queues] || []
    queue_info = queues |> Enum.map(fn {name, count} -> "#{name}:#{count}" end) |> Enum.join(", ")

    jobs_count = try do
      import Ecto.Query
      ChatService.Repo.aggregate(from(j in "oban_jobs", where: j.state in ["available", "executing"]), :count)
    rescue
      _ -> 0
    end

    %{
      name: "Oban Queue",
      status: status,
      details: [
        {"Queues", queue_info},
        {"Active Jobs", jobs_count},
        {"Mode", if(Application.get_env(:chat_service, :queue_mode) == :oban, do: "ACTIVE", else: "Fallback")}
      ]
    }
  end

  defp get_broadway_status do
    status = case Process.whereis(ChatService.Pipelines.WebhookPipeline) do
      nil -> :offline
      pid when is_pid(pid) -> :online
    end

    queue_mode = Application.get_env(:chat_service, :queue_mode, :oban)

    %{
      name: "Broadway",
      status: status,
      details: [
        {"Workers", "#{System.schedulers_online() * 4}"},
        {"Batch Size", "50"},
        {"Mode", if(queue_mode == :rabbitmq, do: "ACTIVE", else: "Disabled")}
      ]
    }
  end

  defp get_backend_status do
    # Now using internal Elixir Agents instead of external Backend API
    status = case ChatService.Services.Ai.Service.health_check() do
      :ok -> :online
      _ -> :offline
    end

    # Get default provider from env
    provider = Application.get_env(:chat_service, :ai_provider, "openai")
    api_key_configured = Application.get_env(:chat_service, :openai_api_key) || System.get_env("OPENAI_API_KEY")

    %{
      name: "AI Agents (Elixir)",
      status: status,
      details: [
        {"Type", "Internal Agents"},
        {"Provider", String.capitalize(provider)},
        {"API Key", if(api_key_configured, do: "Configured", else: "Per Channel")}
      ]
    }
  end

  defp get_line_api_status do
    circuit_state = try do
      ChatService.CircuitBreaker.get_state(:line_api)
    rescue
      _ -> :unknown
    end

    status = case circuit_state do
      :closed -> :online
      :half_open -> :degraded
      :open -> :offline
      _ -> :online
    end

    %{
      name: "LINE API",
      status: status,
      details: [
        {"Endpoint", "api.line.me"},
        {"Circuit", to_string(circuit_state)}
      ]
    }
  end
end
