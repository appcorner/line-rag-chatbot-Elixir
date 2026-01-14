defmodule ChatService.Agents.Tools.Registry do
  @moduledoc false

  use GenServer

  require Logger

  @default_tools [
    ChatService.Agents.Tools.WebScraper,
    ChatService.Agents.Tools.FaqSearch
  ]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns all registered tools.
  """
  def list_tools do
    GenServer.call(__MODULE__, :list_tools)
  end

  @doc """
  Returns tool definitions for specified skill IDs.
  """
  def get_definitions(skill_ids) when is_list(skill_ids) do
    GenServer.call(__MODULE__, {:get_definitions, skill_ids})
  end

  @doc """
  Execute a tool by name with given arguments.
  """
  def execute(tool_name, args) do
    GenServer.call(__MODULE__, {:execute, tool_name, args}, 60_000)
  end

  @doc """
  Register a new tool module.
  """
  def register(tool_module) do
    GenServer.call(__MODULE__, {:register, tool_module})
  end

  @doc """
  Get available skills list for API response.
  """
  def available_skills do
    list_tools()
    |> Enum.map(fn {id, module} ->
      def_info = module.definition()

      enabled =
        if function_exported?(module, :enabled?, 0) do
          module.enabled?()
        else
          true
        end

      %{
        id: id,
        name: def_info[:name],
        description: def_info[:description],
        enabled: enabled
      }
    end)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    tools =
      @default_tools
      |> Enum.map(fn module ->
        name = module.name()
        Logger.info("[ToolsRegistry] Registered tool: #{name}")
        {name, module}
      end)
      |> Map.new()

    {:ok, %{tools: tools}}
  end

  @impl true
  def handle_call(:list_tools, _from, state) do
    {:reply, Map.to_list(state.tools), state}
  end

  @impl true
  def handle_call({:get_definitions, skill_ids}, _from, state) do
    definitions =
      skill_ids
      |> Enum.filter(fn id -> Map.has_key?(state.tools, id) end)
      |> Enum.map(fn id ->
        module = Map.get(state.tools, id)
        module.definition()
      end)

    {:reply, definitions, state}
  end

  @impl true
  def handle_call({:execute, tool_name, args}, _from, state) do
    result =
      case Map.get(state.tools, tool_name) do
        nil ->
          {:error, "Tool not found: #{tool_name}"}

        module ->
          Logger.info("[ToolsRegistry] Executing tool: #{tool_name}")

          try do
            module.execute(args)
          rescue
            e ->
              Logger.error("[ToolsRegistry] Tool execution error: #{Exception.message(e)}")
              {:error, "Tool execution failed: #{Exception.message(e)}"}
          end
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:register, tool_module}, _from, state) do
    name = tool_module.name()
    Logger.info("[ToolsRegistry] Registering tool: #{name}")
    new_tools = Map.put(state.tools, name, tool_module)
    {:reply, :ok, %{state | tools: new_tools}}
  end
end
