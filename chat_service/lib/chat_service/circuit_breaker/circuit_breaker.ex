defmodule ChatService.CircuitBreaker do
  @moduledoc false

  use GenServer

  @failure_threshold 5
  @reset_timeout 30_000
  @half_open_max_calls 3

  defstruct [
    :name,
    state: :closed,
    failure_count: 0,
    success_count: 0,
    last_failure_time: nil,
    half_open_calls: 0
  ]

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(name))
  end

  def call(name, func) do
    case GenServer.call(via_tuple(name), :check_state) do
      :open ->
        {:error, :circuit_open}

      :half_open ->
        execute_half_open(name, func)

      :closed ->
        execute_closed(name, func)
    end
  end

  def get_state(name) do
    GenServer.call(via_tuple(name), :get_state)
  rescue
    _ -> :unknown
  end

  @doc """
  Get states of all circuit breakers.
  """
  def get_all_states do
    [:line_api, :backend_api, :redis]
    |> Enum.map(fn name -> {name, get_state(name)} end)
    |> Map.new()
  end

  def reset(name) do
    GenServer.cast(via_tuple(name), :reset)
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    {:ok, %__MODULE__{name: name}}
  end

  @impl true
  def handle_call(:check_state, _from, state) do
    new_state = maybe_transition(state)
    {:reply, new_state.state, new_state}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state.state, state}
  end

  @impl true
  def handle_cast({:record_success}, state) do
    new_state =
      case state.state do
        :half_open ->
          if state.success_count + 1 >= @half_open_max_calls do
            %{state | state: :closed, failure_count: 0, success_count: 0, half_open_calls: 0}
          else
            %{state | success_count: state.success_count + 1}
          end

        :closed ->
          %{state | failure_count: max(0, state.failure_count - 1)}

        _ ->
          state
      end

    {:noreply, new_state}
  end

  def handle_cast({:record_failure}, state) do
    now = System.monotonic_time(:millisecond)

    new_state =
      case state.state do
        :half_open ->
          %{state | state: :open, last_failure_time: now, failure_count: @failure_threshold}

        :closed ->
          failure_count = state.failure_count + 1

          if failure_count >= @failure_threshold do
            %{state | state: :open, failure_count: failure_count, last_failure_time: now}
          else
            %{state | failure_count: failure_count, last_failure_time: now}
          end

        _ ->
          state
      end

    {:noreply, new_state}
  end

  def handle_cast(:reset, state) do
    {:noreply, %{state | state: :closed, failure_count: 0, success_count: 0, half_open_calls: 0}}
  end

  defp maybe_transition(%{state: :open, last_failure_time: last_failure} = state) do
    now = System.monotonic_time(:millisecond)

    if now - last_failure >= @reset_timeout do
      %{state | state: :half_open, half_open_calls: 0, success_count: 0}
    else
      state
    end
  end

  defp maybe_transition(state), do: state

  defp execute_closed(name, func) do
    case func.() do
      {:ok, _} = result ->
        GenServer.cast(via_tuple(name), {:record_success})
        result

      :ok ->
        GenServer.cast(via_tuple(name), {:record_success})
        :ok

      {:error, _} = error ->
        GenServer.cast(via_tuple(name), {:record_failure})
        error

      other ->
        GenServer.cast(via_tuple(name), {:record_success})
        other
    end
  rescue
    _ ->
      GenServer.cast(via_tuple(name), {:record_failure})
      {:error, :exception}
  end

  defp execute_half_open(name, func) do
    case func.() do
      {:ok, _} = result ->
        GenServer.cast(via_tuple(name), {:record_success})
        result

      :ok ->
        GenServer.cast(via_tuple(name), {:record_success})
        :ok

      {:error, _} = error ->
        GenServer.cast(via_tuple(name), {:record_failure})
        error

      other ->
        GenServer.cast(via_tuple(name), {:record_success})
        other
    end
  rescue
    _ ->
      GenServer.cast(via_tuple(name), {:record_failure})
      {:error, :exception}
  end

  defp via_tuple(name) do
    {:via, Registry, {ChatService.CircuitBreakerRegistry, name}}
  end
end
