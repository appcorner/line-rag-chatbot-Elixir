defmodule ChatService.Telemetry do
  @moduledoc false

  use GenServer

  require Logger

  @metrics_table :chat_service_metrics
  @requests_table :chat_service_requests
  @response_times_table :chat_service_response_times

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    :ets.new(@metrics_table, [:named_table, :set, :public])
    :ets.new(@requests_table, [:named_table, :ordered_set, :public])
    :ets.new(@response_times_table, [:named_table, :ordered_set, :public])

    :ets.insert(@metrics_table, {:messages_received, 0})
    :ets.insert(@metrics_table, {:messages_processed, 0})
    :ets.insert(@metrics_table, {:errors, 0})
    :ets.insert(@metrics_table, {:started_at, System.system_time(:second)})
    :ets.insert(@metrics_table, {:total_response_time_ms, 0})
    :ets.insert(@metrics_table, {:response_count, 0})
    :ets.insert(@metrics_table, {:active_connections, 0})

    attach_handlers()

    # Cleanup old request timestamps every 10 seconds
    :timer.send_interval(10_000, self(), :cleanup_old_requests)

    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup_old_requests, state) do
    cutoff = System.system_time(:millisecond) - 60_000  # Keep last 60 seconds
    :ets.select_delete(@requests_table, [{{:"$1", :_}, [{:<, :"$1", cutoff}], [true]}])
    :ets.select_delete(@response_times_table, [{{:"$1", :_}, [{:<, :"$1", cutoff}], [true]}])
    {:noreply, state}
  end

  def increment(metric, amount \\ 1) do
    :ets.update_counter(@metrics_table, metric, amount, {metric, 0})
  rescue
    ArgumentError -> :ok
  end

  @doc "Record a request timestamp for RPS calculation"
  def record_request do
    now = System.system_time(:millisecond)
    :ets.insert(@requests_table, {now, 1})
    increment(:messages_received)
  rescue
    _ -> :ok
  end

  @doc "Record response time"
  def record_response_time(duration_ms) do
    now = System.system_time(:millisecond)
    :ets.insert(@response_times_table, {now, duration_ms})
    :ets.update_counter(@metrics_table, :total_response_time_ms, round(duration_ms), {:total_response_time_ms, 0})
    :ets.update_counter(@metrics_table, :response_count, 1, {:response_count, 0})
    increment(:messages_processed)
  rescue
    _ -> :ok
  end

  @doc "Track connection count"
  def connection_opened do
    :ets.update_counter(@metrics_table, :active_connections, 1, {:active_connections, 0})
  rescue
    _ -> :ok
  end

  def connection_closed do
    :ets.update_counter(@metrics_table, :active_connections, {2, -1, 0, 0}, {:active_connections, 0})
  rescue
    _ -> :ok
  end

  @doc "Get requests per second (last N seconds)"
  def get_rps(seconds \\ 1) do
    now = System.system_time(:millisecond)
    cutoff = now - (seconds * 1000)

    count = :ets.select_count(@requests_table, [{{:"$1", :_}, [{:>=, :"$1", cutoff}], [true]}])
    Float.round(count / seconds, 2)
  rescue
    _ -> 0.0
  end

  @doc "Get average response time (last 60 seconds)"
  def get_avg_response_time do
    now = System.system_time(:millisecond)
    cutoff = now - 60_000

    times = :ets.select(@response_times_table, [{{:"$1", :"$2"}, [{:>=, :"$1", cutoff}], [:"$2"]}])

    if length(times) > 0 do
      Float.round(Enum.sum(times) / length(times), 1)
    else
      0.0
    end
  rescue
    _ -> 0.0
  end

  @doc "Get active connections count"
  def get_active_connections do
    case :ets.lookup(@metrics_table, :active_connections) do
      [{:active_connections, count}] -> max(count, 0)
      _ -> 0
    end
  rescue
    _ -> 0
  end

  def get_metrics do
    metrics = :ets.tab2list(@metrics_table) |> Enum.into(%{})
    uptime = System.system_time(:second) - Map.get(metrics, :started_at, 0)

    %{
      messages_received: Map.get(metrics, :messages_received, 0),
      messages_processed: Map.get(metrics, :messages_processed, 0),
      errors: Map.get(metrics, :errors, 0),
      active_buffers: get_active_buffer_count(),
      circuit_breakers: get_circuit_breaker_states(),
      uptime_seconds: uptime,
      service: "chat_service",
      version: ChatService.version()
    }
  rescue
    ArgumentError ->
      %{
        messages_received: 0,
        messages_processed: 0,
        errors: 0,
        active_buffers: 0,
        circuit_breakers: %{},
        uptime_seconds: 0,
        service: "chat_service",
        version: ChatService.version()
      }
  end

  def uptime_seconds do
    case :ets.lookup(@metrics_table, :started_at) do
      [{:started_at, started_at}] -> System.system_time(:second) - started_at
      _ -> 0
    end
  rescue
    _ -> 0
  end

  def get_prometheus_format do
    metrics = get_metrics()

    """
    # HELP chat_service_messages_received Total messages received
    # TYPE chat_service_messages_received counter
    chat_service_messages_received #{metrics.messages_received}

    # HELP chat_service_messages_processed Total messages processed
    # TYPE chat_service_messages_processed counter
    chat_service_messages_processed #{metrics.messages_processed}

    # HELP chat_service_errors Total errors
    # TYPE chat_service_errors counter
    chat_service_errors #{metrics.errors}

    # HELP chat_service_active_buffers Active message buffers
    # TYPE chat_service_active_buffers gauge
    chat_service_active_buffers #{metrics.active_buffers}

    # HELP chat_service_uptime_seconds Service uptime in seconds
    # TYPE chat_service_uptime_seconds gauge
    chat_service_uptime_seconds #{metrics.uptime_seconds}
    """
  end

  def record_message_received do
    :telemetry.execute([:chat_service, :webhook, :received], %{count: 1}, %{})
  end

  def record_message_processed(duration_ms) do
    :telemetry.execute([:chat_service, :message, :processed], %{count: 1, duration: duration_ms}, %{})
  end

  def record_error(error_type) do
    :telemetry.execute([:chat_service, :error, :occurred], %{count: 1}, %{type: error_type})
  end

  def record_batch_processed(count) do
    :telemetry.execute([:chat_service, :batch, :processed], %{count: count}, %{})
    increment(:messages_processed, count)
  end

  defp attach_handlers do
    :telemetry.attach_many(
      "chat-service-metrics",
      [
        [:chat_service, :webhook, :received],
        [:chat_service, :message, :processed],
        [:chat_service, :error, :occurred]
      ],
      &handle_event/4,
      nil
    )
  end

  defp handle_event([:chat_service, :webhook, :received], _measurements, _metadata, _config) do
    increment(:messages_received)
  end

  defp handle_event([:chat_service, :message, :processed], _measurements, _metadata, _config) do
    increment(:messages_processed)
  end

  defp handle_event([:chat_service, :error, :occurred], _measurements, _metadata, _config) do
    increment(:errors)
  end

  defp handle_event(_event, _measurements, _metadata, _config), do: :ok

  defp get_active_buffer_count do
    Registry.count(ChatService.BufferRegistry)
  rescue
    _ -> 0
  end

  defp get_circuit_breaker_states do
    [:line_api, :backend_api, :redis]
    |> Enum.map(fn name -> {name, ChatService.CircuitBreaker.get_state(name)} end)
    |> Enum.into(%{})
  end
end
