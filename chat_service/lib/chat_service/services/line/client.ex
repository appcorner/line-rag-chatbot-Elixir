defmodule ChatService.Services.Line.Client do
  @moduledoc false

  require Logger

  @line_api_url "https://api.line.me/v2/bot"

  def reply_message(reply_token, access_token, text) when is_binary(text) do
    reply_message(reply_token, access_token, [%{type: "text", text: text}])
  end

  def reply_message(reply_token, access_token, messages) when is_list(messages) do
    url = "#{@line_api_url}/message/reply"

    body = %{
      replyToken: reply_token,
      messages: messages
    }

    Logger.debug("[LineClient] Sending reply to token: #{String.slice(reply_token || "", 0, 10)}...")

    case http_post(url, body, access_token) do
      {:ok, %{status: 200}} ->
        Logger.info("[LineClient] Reply sent successfully")
        :ok

      {:ok, %{status: 400, body: body}} ->
        # Any 400 error with reply is likely token expired/invalid
        Logger.warning("[LineClient] Reply token expired or invalid: #{inspect(body)}")
        {:error, :token_expired}

      {:ok, %{status: status, body: body}} ->
        Logger.error("[LineClient] Reply failed - HTTP #{status}: #{inspect(body)}")
        {:error, {:line_api_error, status}}

      {:error, reason} ->
        Logger.error("[LineClient] Reply request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def push_message(user_id, access_token, text) when is_binary(text) do
    push_message(user_id, access_token, [%{type: "text", text: text}])
  end

  def push_message(user_id, access_token, messages) when is_list(messages) do
    url = "#{@line_api_url}/message/push"

    body = %{
      to: user_id,
      messages: messages
    }

    Logger.info("[LineClient] Pushing message to user: #{String.slice(user_id || "", 0, 10)}...")

    case http_post(url, body, access_token) do
      {:ok, %{status: 200}} ->
        Logger.info("[LineClient] Push sent successfully")
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.error("[LineClient] Push failed - HTTP #{status}: #{inspect(body)}")
        {:error, {:line_api_error, status}}

      {:error, reason} ->
        Logger.error("[LineClient] Push request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def get_profile(user_id, access_token) do
    url = "#{@line_api_url}/profile/#{user_id}"

    case http_get(url, access_token) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:line_api_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp http_get(url, access_token) do
    Req.get(url,
      finch: ChatService.Finch,
      receive_timeout: 10_000,
      headers: auth_headers(access_token)
    )
    |> handle_response()
  end

  defp http_post(url, body, access_token) do
    http_post_with_retry(url, body, access_token, 2)
  end

  defp http_post_with_retry(url, body, access_token, retries_left) do
    result = Req.post(url,
      json: body,
      finch: ChatService.Finch,
      receive_timeout: 15_000,
      retry: false,
      headers: auth_headers(access_token)
    )

    case result do
      {:error, %Req.HTTPError{reason: reason}} when reason in [:connection_closed, :closed, :timeout] and retries_left > 0 ->
        Logger.warning("[LineClient] Connection error (#{reason}), retrying... (#{retries_left} left)")
        Process.sleep(500)
        http_post_with_retry(url, body, access_token, retries_left - 1)

      {:error, %Mint.TransportError{reason: reason}} when retries_left > 0 ->
        Logger.warning("[LineClient] Transport error (#{reason}), retrying... (#{retries_left} left)")
        Process.sleep(500)
        http_post_with_retry(url, body, access_token, retries_left - 1)

      _ ->
        handle_response(result)
    end
  end

  defp handle_response({:ok, response}) do
    {:ok, %{status: response.status, body: response.body}}
  end

  defp handle_response({:error, _} = error), do: error

  defp auth_headers(access_token) do
    [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{access_token}"}
    ]
  end
end
