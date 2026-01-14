defmodule ChatService.GracefulShutdown do
  @moduledoc false

  use GenServer

  require Logger

  @shutdown_timeout 30_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def shutdown do
    GenServer.call(__MODULE__, :shutdown, @shutdown_timeout)
  end

  def is_shutting_down? do
    GenServer.call(__MODULE__, :is_shutting_down?)
  end

  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)
    {:ok, %{shutting_down: false}}
  end

  @impl true
  def handle_call(:shutdown, _from, state) do
    Logger.info("Graceful shutdown initiated")
    perform_shutdown()
    {:reply, :ok, %{state | shutting_down: true}}
  end

  def handle_call(:is_shutting_down?, _from, state) do
    {:reply, state.shutting_down, state}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  defp perform_shutdown do
    Logger.info("Waiting for active requests to complete")

    wait_for_buffers()
    drain_connections()

    Logger.info("Shutdown complete")
  end

  defp wait_for_buffers do
    case Registry.count(ChatService.BufferRegistry) do
      0 ->
        :ok

      count ->
        Logger.info("Waiting for #{count} message buffers")
        Process.sleep(1000)
        wait_for_buffers()
    end
  end

  defp drain_connections do
    Process.sleep(1000)
  end
end
