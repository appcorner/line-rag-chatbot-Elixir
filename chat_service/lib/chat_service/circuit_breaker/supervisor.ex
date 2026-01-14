defmodule ChatService.CircuitBreaker.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    children = [
      {Registry, keys: :unique, name: ChatService.CircuitBreakerRegistry},
      Supervisor.child_spec({ChatService.CircuitBreaker, name: :line_api}, id: :cb_line_api),
      Supervisor.child_spec({ChatService.CircuitBreaker, name: :backend_api}, id: :cb_backend_api),
      Supervisor.child_spec({ChatService.CircuitBreaker, name: :redis}, id: :cb_redis)
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
