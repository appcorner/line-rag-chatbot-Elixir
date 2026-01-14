defmodule ChatService.Agents.Providers.Anthropic do
  @moduledoc false

  @behaviour ChatService.Agents.Provider

  require Logger

  @api_url "https://api.anthropic.com/v1/messages"
  @api_version "2023-06-01"

  @impl true
  def name, do: "anthropic"

  @impl true
  def default_model, do: "claude-sonnet-4-20250514"

  @impl true
  def available_models do
    [
      "claude-opus-4-20250514",
      "claude-sonnet-4-20250514",
      "claude-3-5-sonnet-20241022",
      "claude-3-5-haiku-20241022",
      "claude-3-opus-20240229",
      "claude-3-sonnet-20240229",
      "claude-3-haiku-20240307"
    ]
  end

  @impl true
  def validate_api_key(api_key) do
    if String.starts_with?(api_key, "sk-ant-") do
      :ok
    else
      {:error, "Anthropic API key should start with 'sk-ant-'"}
    end
  end

  @impl true
  def chat(messages, tools, config) do
    {system_message, other_messages} = extract_system_message(messages)

    body =
      %{
        model: config[:model] || default_model(),
        max_tokens: config[:max_tokens] || 2000,
        messages: format_messages(other_messages)
      }
      |> maybe_add_system(system_message)
      |> maybe_add_tools(tools)

    headers = [
      {"content-type", "application/json"},
      {"x-api-key", config[:api_key]},
      {"anthropic-version", @api_version}
    ]

    case do_request(@api_url, body, headers) do
      {:ok, response} ->
        parse_response(response)

      {:error, reason} ->
        Logger.error("[Anthropic] Request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp extract_system_message(messages) do
    system =
      Enum.find(messages, fn msg ->
        (msg[:role] || msg["role"]) == "system"
      end)

    others =
      Enum.reject(messages, fn msg ->
        (msg[:role] || msg["role"]) == "system"
      end)

    system_content = if system, do: system[:content] || system["content"], else: nil
    {system_content, others}
  end

  defp format_messages(messages) do
    Enum.map(messages, fn msg ->
      role = msg[:role] || msg["role"]
      content = msg[:content] || msg["content"]

      # Convert "tool" role to tool_result content block
      case role do
        "tool" ->
          %{
            role: "user",
            content: [
              %{
                type: "tool_result",
                tool_use_id: msg[:tool_call_id] || msg["tool_call_id"],
                content: content
              }
            ]
          }

        "assistant" ->
          # Check if has tool calls
          case msg[:tool_calls] || msg["tool_calls"] do
            nil ->
              %{role: role, content: content || ""}

            [] ->
              %{role: role, content: content || ""}

            tool_calls ->
              content_blocks =
                if content && content != "" do
                  [%{type: "text", text: content}]
                else
                  []
                end

              tool_blocks =
                Enum.map(tool_calls, fn tc ->
                  %{
                    type: "tool_use",
                    id: tc[:id] || tc["id"],
                    name: tc[:function][:name] || tc["function"]["name"],
                    input: parse_arguments(tc[:function][:arguments] || tc["function"]["arguments"])
                  }
                end)

              %{role: "assistant", content: content_blocks ++ tool_blocks}
          end

        _ ->
          %{role: role, content: content}
      end
    end)
  end

  defp parse_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, parsed} -> parsed
      {:error, _} -> %{}
    end
  end

  defp parse_arguments(args) when is_map(args), do: args
  defp parse_arguments(_), do: %{}

  defp maybe_add_system(body, nil), do: body
  defp maybe_add_system(body, ""), do: body
  defp maybe_add_system(body, system), do: Map.put(body, :system, system)

  defp maybe_add_tools(body, []), do: body

  defp maybe_add_tools(body, tools) when is_list(tools) do
    formatted_tools =
      Enum.map(tools, fn tool ->
        %{
          name: tool[:name] || tool["name"],
          description: tool[:description] || tool["description"],
          input_schema: tool[:parameters] || tool["parameters"] || %{type: "object", properties: %{}}
        }
      end)

    Map.put(body, :tools, formatted_tools)
  end

  defp do_request(url, body, headers) do
    request =
      Finch.build(:post, url, headers, Jason.encode!(body))

    case Finch.request(request, ChatService.Finch, receive_timeout: 120_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        {:ok, Jason.decode!(body)}

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{body}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_response(%{"content" => content} = response) do
    # Find text content
    text_content =
      content
      |> Enum.find(fn c -> c["type"] == "text" end)
      |> case do
        nil -> nil
        %{"text" => text} -> text
      end

    # Find tool use
    tool_calls =
      content
      |> Enum.filter(fn c -> c["type"] == "tool_use" end)
      |> Enum.map(fn tc ->
        %{
          id: tc["id"],
          type: "function",
          function: %{
            name: tc["name"],
            arguments: Jason.encode!(tc["input"] || %{})
          }
        }
      end)

    result = %{
      content: text_content,
      tool_calls: tool_calls,
      usage: response["usage"]
    }

    {:ok, result}
  end

  defp parse_response(response) do
    {:error, "Unexpected response format: #{inspect(response)}"}
  end
end
