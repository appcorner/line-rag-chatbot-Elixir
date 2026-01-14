defmodule ChatService.Agents.Chat do
  @moduledoc false

  require Logger

  alias ChatService.Agents.Tools.Registry, as: ToolsRegistry

  @providers %{
    "openai" => ChatService.Agents.Providers.OpenAI,
    "anthropic" => ChatService.Agents.Providers.Anthropic,
    "google" => ChatService.Agents.Providers.Google
  }

  @max_tool_iterations 5

  @type chat_request :: %{
          message: String.t(),
          provider: String.t(),
          model: String.t() | nil,
          api_key: String.t(),
          skills: [String.t()],
          system_prompt: String.t() | nil,
          conversation_id: String.t() | nil
        }

  @type chat_response :: %{
          status: String.t(),
          message: String.t(),
          conversation_id: String.t() | nil,
          provider: String.t(),
          model: String.t(),
          skills: [String.t()],
          tool_used: String.t() | nil
        }

  @doc """
  Process a chat message with optional tool calling.
  """
  @spec process(chat_request()) :: {:ok, chat_response()} | {:error, term()}
  def process(request) do
    provider_name = request[:provider] || "openai"

    with {:ok, provider_module} <- get_provider(provider_name),
         {:ok, result} <- do_chat(provider_module, request) do
      {:ok, result}
    end
  end

  defp get_provider(name) do
    case Map.get(@providers, name) do
      nil ->
        Logger.error("[Chat] Unknown provider: #{name}")
        {:error, "Provider #{name} not supported"}

      module ->
        {:ok, module}
    end
  end

  defp do_chat(provider_module, request) do
    api_key = request[:api_key]
    model = request[:model] || provider_module.default_model()
    skills = request[:skills] || []
    message = request[:message]
    conversation_id = request[:conversation_id]
    history = request[:history] || []
    max_tokens = request[:max_tokens]
    temperature = request[:temperature]

    Logger.info("[Chat] Processing: provider=#{provider_module.name()}, model=#{model}, skills=#{inspect(skills)}, history=#{length(history)}, max_tokens=#{max_tokens || "default"}")

    # Build initial messages
    system_prompt = request[:system_prompt] || default_system_prompt()

    # Include conversation history
    messages = [
      %{role: "system", content: system_prompt}
    ] ++ history ++ [
      %{role: "user", content: message}
    ]

    # Get tool definitions
    tools = ToolsRegistry.get_definitions(skills)

    # Build config with optional max_tokens and temperature
    config =
      %{api_key: api_key, model: model}
      |> maybe_put(:max_tokens, max_tokens)
      |> maybe_put(:temperature, temperature)

    # If no skills/tools are provided, skip tool handling entirely
    if skills == [] do
      Logger.info("[Chat] No skills provided - direct chat without tools")
      handle_chat_loop(provider_module, messages, [], config, 0, conversation_id, skills)
    else
      # Normal chat with potential tool calls
      handle_chat_loop(provider_module, messages, tools, config, 0, conversation_id, skills)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp handle_chat_loop(_provider, _messages, _tools, _config, iteration, _conv_id, _skills)
       when iteration >= @max_tool_iterations do
    {:error, "Maximum tool iterations reached"}
  end

  defp handle_chat_loop(provider_module, messages, tools, config, iteration, conversation_id, skills) do
    case provider_module.chat(messages, tools, config) do
      {:ok, %{tool_calls: tool_calls, content: content}} when tool_calls != [] ->
        Logger.info("[Chat] Tool calls detected: #{inspect(Enum.map(tool_calls, & &1.function.name))}")

        # Execute tools
        {tool_results, tool_used} = execute_tool_calls(tool_calls)

        # Build new messages with tool results
        assistant_msg = %{
          role: "assistant",
          content: content,
          tool_calls: tool_calls
        }

        tool_msgs =
          Enum.map(tool_results, fn {call_id, result} ->
            %{
              role: "tool",
              tool_call_id: call_id,
              content: result
            }
          end)

        new_messages = messages ++ [assistant_msg | tool_msgs]

        # Continue chat loop without tools (to get final response)
        handle_chat_loop(provider_module, new_messages, [], config, iteration + 1, conversation_id, skills)
        |> case do
          {:ok, response} -> {:ok, Map.put(response, :tool_used, tool_used)}
          error -> error
        end

      {:ok, %{content: content}} ->
        {:ok,
         %{
           status: "success",
           message: content || "ไม่สามารถประมวลผลได้",
           conversation_id: conversation_id,
           provider: provider_module.name(),
           model: config[:model],
           skills: skills,
           tool_used: nil
         }}

      {:error, reason} ->
        Logger.error("[Chat] Provider error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp execute_tool_calls(tool_calls) do
    results =
      Enum.map(tool_calls, fn call ->
        function = call.function || call[:function]
        name = function.name || function[:name]
        args_str = function.arguments || function[:arguments]

        args =
          case Jason.decode(args_str) do
            {:ok, parsed} -> parsed
            {:error, _} -> %{}
          end

        Logger.info("[Chat] Executing tool: #{name} with args: #{inspect(args)}")

        result =
          case ToolsRegistry.execute(name, args) do
            {:ok, result} -> result
            {:error, reason} -> "Error: #{reason}"
          end

        call_id = call.id || call[:id]
        {call_id, result}
      end)

    # Get first tool used
    first_tool =
      case tool_calls do
        [first | _] -> (first.function || first[:function]).name || (first.function || first[:function])[:name]
        _ -> nil
      end

    {results, first_tool}
  end

  defp default_system_prompt do
    """
    คุณเป็น AI Assistant ที่เป็นมิตรและช่วยเหลือผู้ใช้

    กฎสำคัญ:
    1. ตอบเป็นภาษาไทย
    2. ถ้ามี tools ให้ใช้เมื่อจำเป็น
    3. ตอบอย่างสุภาพและเป็นประโยชน์
    """
  end

  @doc """
  Process a chat message for a specific agent.
  This is a convenience wrapper that looks up agent config and calls process/1.
  """
  def process(agent_id, message, context \\ %{}) do
    case ChatService.Agents.Supervisor.get_agent(agent_id) do
      {:ok, agent} ->
        request = %{
          message: message,
          provider: agent.provider,
          model: agent.model,
          api_key: Map.get(context, :api_key) || Map.get(context, "api_key"),
          skills: agent.skills,
          system_prompt: agent.system_prompt,
          conversation_id: Map.get(context, :conversation_id) || Map.get(context, "conversation_id")
        }
        process(request)

      {:error, :not_found} ->
        {:error, "Agent not found"}
    end
  end

  @doc """
  Stream chat responses for a specific agent.
  Calls the callback function with each chunk of the response.
  """
  def stream(agent_id, message, context, callback) when is_function(callback, 1) do
    case process(agent_id, message, context) do
      {:ok, response} ->
        # Simulate streaming by calling callback with the full response
        # In a real implementation, this would stream from the provider
        callback.({:chunk, response.message})
        callback.({:done, response})
        {:ok, response}

      {:error, reason} ->
        callback.({:error, reason})
        {:error, reason}
    end
  end

  @doc """
  Returns available providers list.
  """
  def available_providers do
    Enum.map(@providers, fn {id, module} ->
      %{
        id: id,
        name: module.name(),
        models: module.available_models()
      }
    end)
  end
end
