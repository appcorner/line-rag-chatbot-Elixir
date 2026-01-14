defmodule ChatService.Agents.Providers.OpenAI do
  @moduledoc false

  @behaviour ChatService.Agents.Provider

  require Logger

  @api_url "https://api.openai.com/v1/chat/completions"

  @impl true
  def name, do: "openai"

  @impl true
  def default_model, do: "gpt-4o"

  @impl true
  def available_models do
    [
      "gpt-4o",
      "gpt-4o-mini",
      "gpt-4-turbo",
      "gpt-4-turbo-preview",
      "gpt-4",
      "gpt-3.5-turbo"
    ]
  end

  @impl true
  def validate_api_key(api_key) do
    if String.starts_with?(api_key, "sk-") do
      :ok
    else
      {:error, "OpenAI API key should start with 'sk-'"}
    end
  end

  @impl true
  def chat(messages, tools, config) do
    body =
      %{
        model: config[:model] || default_model(),
        messages: format_messages(messages),
        temperature: config[:temperature] || 0.7,
        max_tokens: config[:max_tokens] || 2000
      }
      |> maybe_add_tools(tools)

    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{config[:api_key]}"}
    ]

    case do_request(@api_url, body, headers) do
      {:ok, response} ->
        parse_response(response)

      {:error, reason} ->
        Logger.error("[OpenAI] Request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp format_messages(messages) do
    Enum.map(messages, fn msg ->
      base = %{
        role: msg[:role] || msg["role"],
        content: msg[:content] || msg["content"]
      }

      # Handle tool calls in assistant messages
      base =
        case msg[:tool_calls] || msg["tool_calls"] do
          nil -> base
          [] -> base
          tool_calls -> Map.put(base, :tool_calls, tool_calls)
        end

      # Handle tool response messages
      case msg[:tool_call_id] || msg["tool_call_id"] do
        nil -> base
        id -> Map.put(base, :tool_call_id, id)
      end
    end)
  end

  defp maybe_add_tools(body, []), do: body

  defp maybe_add_tools(body, tools) when is_list(tools) do
    formatted_tools =
      Enum.map(tools, fn tool ->
        %{
          type: "function",
          function: %{
            name: tool[:name] || tool["name"],
            description: tool[:description] || tool["description"],
            parameters: tool[:parameters] || tool["parameters"] || %{type: "object", properties: %{}}
          }
        }
      end)

    body
    |> Map.put(:tools, formatted_tools)
    |> Map.put(:tool_choice, "auto")
  end

  defp do_request(url, body, headers) do
    request =
      Finch.build(:post, url, headers, Jason.encode!(body))

    case Finch.request(request, ChatService.Finch, receive_timeout: 60_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        {:ok, Jason.decode!(body)}

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{body}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_response(%{"choices" => [choice | _]} = response) do
    message = choice["message"]

    result = %{
      content: message["content"],
      tool_calls: parse_tool_calls(message["tool_calls"]),
      usage: response["usage"]
    }

    {:ok, result}
  end

  defp parse_response(response) do
    {:error, "Unexpected response format: #{inspect(response)}"}
  end

  defp parse_tool_calls(nil), do: []
  defp parse_tool_calls([]), do: []

  defp parse_tool_calls(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      %{
        id: tc["id"],
        type: "function",
        function: %{
          name: tc["function"]["name"],
          arguments: tc["function"]["arguments"]
        }
      }
    end)
  end
end
