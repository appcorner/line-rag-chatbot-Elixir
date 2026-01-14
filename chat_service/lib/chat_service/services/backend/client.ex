defmodule ChatService.Services.Backend.Client do
  @moduledoc false

  require Logger

  def get_channel(channel_id) do
    url = "#{backend_url()}/api/line-oas/by-channel/#{channel_id}"

    case http_get(url) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:backend_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def process_message(channel, user_id, text) do
    url = "#{backend_url()}/api/chat/process"

    body = %{
      channel_id: channel.id,
      line_user_id: user_id,
      message: text,
      message_type: "text"
    }

    case http_post(url, body) do
      {:ok, %{status: 200, body: %{"response" => response}}} ->
        {:ok, response}

      {:ok, %{status: 200, body: %{"text" => response}}} ->
        {:ok, response}

      {:ok, %{status: status}} ->
        {:error, {:backend_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def process_agent_chat(params) do
    url = "#{backend_url()}/api/agents/chat"

    body = %{
      message: params.message,
      conversationId: params.conversation_id,
      provider: params.provider,
      model: params.model,
      apiKey: params.api_key,
      skills: params.skills,
      systemPrompt: params.system_prompt
    }

    case http_post(url, body) do
      {:ok, %{status: 200, body: response}} ->
        {:ok, response}

      {:ok, %{status: status}} ->
        {:error, {:backend_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def health_check do
    url = "#{backend_url()}/health"

    case http_get(url) do
      {:ok, %{status: 200}} -> :ok
      _ -> :error
    end
  end

  defp http_get(url) do
    Req.get(url,
      finch: ChatService.Finch,
      receive_timeout: 30_000,
      headers: default_headers()
    )
    |> handle_response()
  end

  defp http_post(url, body) do
    Req.post(url,
      json: body,
      finch: ChatService.Finch,
      receive_timeout: 60_000,
      headers: default_headers()
    )
    |> handle_response()
  end

  defp handle_response({:ok, response}) do
    {:ok, %{status: response.status, body: response.body}}
  end

  defp handle_response({:error, _} = error), do: error

  defp default_headers do
    token = Application.get_env(:chat_service, :internal_service_token)

    headers = [
      {"content-type", "application/json"},
      {"x-service", "chat-service-elixir"}
    ]

    if token do
      [{"x-service-token", token} | headers]
    else
      headers
    end
  end

  defp backend_url do
    Application.get_env(:chat_service, :backend_url, "http://localhost:8000")
  end
end
