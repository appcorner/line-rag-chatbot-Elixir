defmodule ChatService.Agents.Providers.Google do
  @moduledoc false

  @behaviour ChatService.Agents.Provider

  require Logger

  @api_base "https://generativelanguage.googleapis.com/v1beta/models"

  @impl true
  def name, do: "google"

  @impl true
  def default_model, do: "gemini-2.0-flash-exp"

  @impl true
  def available_models do
    [
      "gemini-2.5-pro",
      "gemini-2.5-flash",
      "gemini-2.0-flash-exp",
      "gemini-2.0-flash",
      "gemini-1.5-pro",
      "gemini-1.5-flash"
    ]
  end

  @impl true
  def chat(messages, tools, config) do
    model = config[:model] || default_model()
    api_key = config[:api_key]

    Logger.info("[Google] Using model: #{model}, messages: #{length(messages)}")

    {system_instruction, contents} = format_messages(messages)

    # Gemini 2.5 models use thinking tokens, need higher limit
    default_max_tokens = if String.contains?(model, "2.5"), do: 16000, else: 4000
    max_tokens = config[:max_tokens] || default_max_tokens

    Logger.debug("[Google] Using max_tokens: #{max_tokens}")

    body =
      %{
        contents: contents,
        generationConfig: %{
          temperature: config[:temperature] || 0.7,
          maxOutputTokens: max_tokens
        }
      }
      |> maybe_add_system(system_instruction)
      |> maybe_add_tools(tools)

    url = "#{@api_base}/#{model}:generateContent?key=#{api_key}"

    headers = [
      {"content-type", "application/json"}
    ]

    case do_request(url, body, headers) do
      {:ok, response} ->
        parse_response(response)

      {:error, reason} ->
        Logger.error("[Google] Request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp format_messages(messages) do
    # Extract system message
    system =
      Enum.find(messages, fn msg ->
        (msg[:role] || msg["role"]) == "system"
      end)

    system_instruction =
      if system do
        %{parts: [%{text: system[:content] || system["content"]}]}
      else
        nil
      end

    # Format other messages
    contents =
      messages
      |> Enum.reject(fn msg -> (msg[:role] || msg["role"]) == "system" end)
      |> Enum.map(fn msg ->
        role = msg[:role] || msg["role"]
        content = msg[:content] || msg["content"]

        gemini_role =
          case role do
            "assistant" -> "model"
            "tool" -> "function"
            _ -> "user"
          end

        parts =
          case role do
            "tool" ->
              [
                %{
                  functionResponse: %{
                    name: msg[:name] || msg["name"] || "tool",
                    response: %{result: content}
                  }
                }
              ]

            "assistant" ->
              case msg[:tool_calls] || msg["tool_calls"] do
                nil ->
                  [%{text: content || ""}]

                [] ->
                  [%{text: content || ""}]

                tool_calls ->
                  text_parts = if content && content != "", do: [%{text: content}], else: []

                  function_parts =
                    Enum.map(tool_calls, fn tc ->
                      args = tc[:function][:arguments] || tc["function"]["arguments"]

                      parsed_args =
                        case args do
                          s when is_binary(s) ->
                            case Jason.decode(s) do
                              {:ok, map} -> map
                              _ -> %{}
                            end

                          m when is_map(m) ->
                            m

                          _ ->
                            %{}
                        end

                      %{
                        functionCall: %{
                          name: tc[:function][:name] || tc["function"]["name"],
                          args: parsed_args
                        }
                      }
                    end)

                  text_parts ++ function_parts
              end

            _ ->
              [%{text: content}]
          end

        %{role: gemini_role, parts: parts}
      end)

    {system_instruction, contents}
  end

  defp maybe_add_system(body, nil), do: body
  defp maybe_add_system(body, system), do: Map.put(body, :systemInstruction, system)

  defp maybe_add_tools(body, []), do: body

  defp maybe_add_tools(body, tools) when is_list(tools) do
    function_declarations =
      Enum.map(tools, fn tool ->
        %{
          name: tool[:name] || tool["name"],
          description: tool[:description] || tool["description"],
          parameters: tool[:parameters] || tool["parameters"] || %{type: "object", properties: %{}}
        }
      end)

    Map.put(body, :tools, [%{functionDeclarations: function_declarations}])
  end

  defp do_request(url, body, headers) do
    # Don't log the full URL (contains API key)
    Logger.debug("[Google] Making request to Gemini API")

    request =
      Finch.build(:post, url, headers, Jason.encode!(body))

    # Gemini 2.5 models can take longer due to "thinking" - use generous timeouts
    opts = [
      pool_timeout: 60_000,
      receive_timeout: 120_000
    ]

    case Finch.request(request, ChatService.Finch, opts) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        Logger.debug("[Google] Request successful")
        {:ok, Jason.decode!(body)}

      {:ok, %Finch.Response{status: status, body: body}} ->
        Logger.error("[Google] API error - HTTP #{status}: #{String.slice(body, 0, 500)}")
        {:error, "HTTP #{status}: #{body}"}

      {:error, reason} ->
        Logger.error("[Google] Request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp parse_response(%{"candidates" => [candidate | _]} = response) do
    content = candidate["content"]
    parts = content["parts"] || []
    finish_reason = candidate["finishReason"]

    Logger.debug("[Google] Parse response - finishReason: #{finish_reason}, parts: #{inspect(parts)}")

    # Find text content
    text_content =
      parts
      |> Enum.find(fn p -> Map.has_key?(p, "text") end)
      |> case do
        nil -> nil
        %{"text" => text} -> text
      end

    Logger.debug("[Google] Extracted text_content: #{inspect(text_content)}")

    # Find function calls
    tool_calls =
      parts
      |> Enum.filter(fn p -> Map.has_key?(p, "functionCall") end)
      |> Enum.map(fn %{"functionCall" => fc} ->
        %{
          id: "call_#{:erlang.unique_integer([:positive])}",
          type: "function",
          function: %{
            name: fc["name"],
            arguments: Jason.encode!(fc["args"] || %{})
          }
        }
      end)

    result = %{
      content: text_content,
      tool_calls: tool_calls,
      usage: response["usageMetadata"]
    }

    {:ok, result}
  end

  defp parse_response(response) do
    {:error, "Unexpected response format: #{inspect(response)}"}
  end
end
