defmodule ChatService.Services.Line.Api do
  @moduledoc false

  require Logger

  @line_api_base "https://api.line.me/v2/bot"

  @doc """
  Get user profile from LINE API.
  Returns {:ok, profile} or {:error, reason}
  """
  def get_profile(user_id, access_token) do
    url = "#{@line_api_base}/profile/#{user_id}"

    case Req.get(url,
           headers: [{"Authorization", "Bearer #{access_token}"}],
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, %{
          user_id: body["userId"],
          display_name: body["displayName"],
          picture_url: body["pictureUrl"],
          status_message: body["statusMessage"],
          language: body["language"]
        }}

      {:ok, %{status: 404}} ->
        {:error, :user_not_found}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("LINE API error: status=#{status}, body=#{inspect(body)}")
        {:error, :api_error}

      {:error, reason} ->
        Logger.error("LINE API request failed: #{inspect(reason)}")
        {:error, :request_failed}
    end
  end

  @doc """
  Reply to a message using reply token.
  """
  def reply_message(reply_token, messages, access_token) when is_list(messages) do
    url = "#{@line_api_base}/message/reply"

    body = %{
      replyToken: reply_token,
      messages: messages
    }

    case Req.post(url,
           json: body,
           headers: [{"Authorization", "Bearer #{access_token}"}],
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.warning("LINE reply failed: status=#{status}, body=#{inspect(body)}")
        {:error, :reply_failed}

      {:error, reason} ->
        Logger.error("LINE reply request failed: #{inspect(reason)}")
        {:error, :request_failed}
    end
  end

  def reply_message(reply_token, message, access_token) when is_binary(message) do
    reply_message(reply_token, [%{type: "text", text: message}], access_token)
  end

  @doc """
  Push a message to a user.
  """
  def push_message(user_id, messages, access_token) when is_list(messages) do
    url = "#{@line_api_base}/message/push"

    body = %{
      to: user_id,
      messages: messages
    }

    Logger.info("LINE push to #{user_id}, token: #{String.slice(access_token || "", 0, 20)}...")

    case Req.post(url,
           json: body,
           headers: [
             {"Authorization", "Bearer #{access_token}"},
             {"Content-Type", "application/json"}
           ],
           connect_options: [timeout: 30_000],
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200}} ->
        Logger.info("LINE push success")
        :ok

      {:ok, %{status: status, body: resp_body}} ->
        Logger.warning("LINE push failed: status=#{status}, body=#{inspect(resp_body)}")
        {:error, :push_failed}

      {:error, reason} ->
        Logger.error("LINE push request failed: #{inspect(reason)}")
        {:error, :request_failed}
    end
  end

  def push_message(user_id, message, access_token) when is_binary(message) do
    push_message(user_id, [%{type: "text", text: message}], access_token)
  end

  @doc """
  Push an image message to a user.
  """
  def push_image(user_id, image_url, access_token, preview_url \\ nil) do
    message = %{
      type: "image",
      originalContentUrl: image_url,
      previewImageUrl: preview_url || image_url
    }
    push_message(user_id, [message], access_token)
  end

  @doc """
  Push multiple images to a user (max 5 per request).
  """
  def push_images(user_id, image_urls, access_token) when is_list(image_urls) do
    messages = image_urls
    |> Enum.take(5)
    |> Enum.map(fn url ->
      %{
        type: "image",
        originalContentUrl: url,
        previewImageUrl: url
      }
    end)
    push_message(user_id, messages, access_token)
  end

  @doc """
  Push a flex message with image carousel.
  """
  def push_image_carousel(user_id, images, access_token) when is_list(images) do
    bubbles = images
    |> Enum.take(12)
    |> Enum.map(fn image ->
      %{
        type: "bubble",
        hero: %{
          type: "image",
          url: image.url,
          size: "full",
          aspectRatio: "4:3",
          aspectMode: "cover",
          action: %{
            type: "uri",
            uri: image.url
          }
        },
        body: if(image[:caption], do: %{
          type: "box",
          layout: "vertical",
          contents: [
            %{type: "text", text: image.caption, size: "sm", color: "#666666"}
          ]
        }, else: nil)
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()
    end)

    flex_message = %{
      type: "flex",
      altText: "Images",
      contents: %{
        type: "carousel",
        contents: bubbles
      }
    }

    push_message(user_id, [flex_message], access_token)
  end

  @doc """
  Get message content (for images, videos, audio, files).
  """
  def get_content(message_id, access_token) do
    url = "https://api-data.line.me/v2/bot/message/#{message_id}/content"

    case Req.get(url,
           headers: [{"Authorization", "Bearer #{access_token}"}],
           receive_timeout: 30_000,
           decode_body: false
         ) do
      {:ok, %{status: 200, body: body, headers: headers}} ->
        content_type = get_header(headers, "content-type")
        {:ok, %{content: body, content_type: content_type}}

      {:ok, %{status: status}} ->
        {:error, {:status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_header(headers, key) do
    headers
    |> Enum.find(fn {k, _v} -> String.downcase(k) == key end)
    |> case do
      {_, value} -> value
      nil -> nil
    end
  end
end
