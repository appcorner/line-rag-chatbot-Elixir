defmodule ChatService.Agents.Supervisor do
  @moduledoc """
  Supervisor for AI agents and related processes.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # Registry for dynamic agents
      {Registry, keys: :unique, name: ChatService.AgentsRegistry},
      # Dynamic supervisor for agent processes
      {DynamicSupervisor, strategy: :one_for_one, name: ChatService.AgentsDynamicSupervisor},
      # Tools registry
      ChatService.Agents.Tools.Registry
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  List all running agents.
  """
  def list_agents do
    Registry.select(ChatService.AgentsRegistry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$3"}}]}])
    |> Enum.map(fn {id, config} -> Map.put(config, :id, id) end)
  end

  @doc """
  Get a specific agent by ID.
  """
  def get_agent(agent_id) do
    case Registry.lookup(ChatService.AgentsRegistry, agent_id) do
      [{_pid, config}] -> {:ok, Map.put(config, :id, agent_id)}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Start a new agent with the given configuration.
  """
  def start_agent(params) do
    agent_id = Map.get(params, "id") || generate_agent_id()
    config = %{
      id: agent_id,
      provider: Map.get(params, "provider", "openai"),
      model: Map.get(params, "model"),
      system_prompt: Map.get(params, "system_prompt"),
      skills: Map.get(params, "skills", []),
      created_at: DateTime.utc_now()
    }

    # Register the agent in the registry
    case Registry.register(ChatService.AgentsRegistry, agent_id, config) do
      {:ok, _} -> {:ok, config}
      {:error, {:already_registered, _}} -> {:error, :already_exists}
    end
  end

  @doc """
  Stop an agent by ID.
  """
  def stop_agent(agent_id) do
    case Registry.lookup(ChatService.AgentsRegistry, agent_id) do
      [{pid, _}] ->
        Registry.unregister(ChatService.AgentsRegistry, agent_id)
        Process.exit(pid, :normal)
        :ok
      [] ->
        {:error, :not_found}
    end
  end

  defp generate_agent_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
