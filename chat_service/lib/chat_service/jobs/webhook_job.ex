defmodule ChatService.Jobs.WebhookJob do
  @moduledoc """
  Oban job for processing LINE webhook events.
  This ensures webhook processing is:
  - Persistent (survives crashes/restarts)
  - Retryable (automatic retry on failure)
  - Traceable (job history in database)
  """
  use Oban.Worker,
    queue: :webhook,
    max_attempts: 3,
    priority: 0

  require Logger

  alias ChatService.Services.User.Service, as: UserService

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event" => event, "channel" => channel}}) do
    # Reconstruct channel as map with atom keys for compatibility
    channel = atomize_keys(channel)

    try do
      # Broadcast for real-time monitoring
      broadcast_webhook_event(event, channel)

      # Process the event
      process_event(event, channel)

      :ok
    rescue
      e ->
        Logger.error("Webhook job error: #{inspect(e)}")
        {:error, inspect(e)}
    end
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), atomize_keys(v)}
      {k, v} -> {k, atomize_keys(v)}
    end)
  rescue
    _ -> map
  end

  defp atomize_keys(value), do: value

  defp broadcast_webhook_event(event, channel) do
    Phoenix.PubSub.broadcast(ChatService.PubSub, "webhooks", {:webhook_received, %{
      channel_id: channel[:channel_id],
      event_type: event["type"],
      user_id: get_in(event, ["source", "userId"]),
      message_type: get_in(event, ["message", "type"]),
      message_text: get_in(event, ["message", "text"]),
      raw: event
    }})
  end

  defp process_event(%{"type" => "message"} = event, channel) do
    user_id = get_in(event, ["source", "userId"])
    reply_token = event["replyToken"]

    # Get or create user profile
    {:ok, user} = ensure_user_profile(user_id, channel)
    broadcast_user_update(user, channel)

    case event["message"] do
      %{"type" => "text", "text" => text} ->
        ChatService.Workers.MessageBuffer.add_message(
          channel[:channel_id],
          user_id,
          text,
          reply_token,
          channel
        )
      _ ->
        :ok
    end
  end

  defp process_event(%{"type" => "follow"} = event, channel) do
    user_id = get_in(event, ["source", "userId"])

    case ensure_user_profile(user_id, channel) do
      {:ok, user} ->
        Logger.info("New follower: #{user_id} (#{user.display_name || "unknown"}) on channel #{channel[:channel_id]}")
        broadcast_user_update(user, channel)

      {:error, reason} ->
        Logger.warning("Failed to get profile for follower #{user_id}: #{inspect(reason)}")
    end

    :ok
  end

  defp process_event(%{"type" => "unfollow"} = event, channel) do
    user_id = get_in(event, ["source", "userId"])
    Logger.info("Unfollowed: #{user_id} from channel #{channel[:channel_id]}")
    :ok
  end

  defp process_event(%{"type" => "postback"} = event, channel) do
    user_id = get_in(event, ["source", "userId"])
    data = get_in(event, ["postback", "data"])

    {:ok, _user} = ensure_user_profile(user_id, channel)

    Logger.info("Postback from #{user_id}: #{data} on channel #{channel[:channel_id]}")
    :ok
  end

  defp process_event(_event, _channel), do: :ok

  defp ensure_user_profile(user_id, channel) when is_binary(user_id) do
    channel_struct = %{
      id: channel[:id],
      channel_id: channel[:channel_id],
      access_token: channel[:access_token]
    }

    UserService.get_or_create_user(user_id, channel_struct)
  end

  defp ensure_user_profile(nil, _channel), do: {:error, :no_user_id}

  defp broadcast_user_update(user, channel) do
    Phoenix.PubSub.broadcast(ChatService.PubSub, "users", {:user_updated, %{
      line_user_id: user.line_user_id,
      display_name: user.display_name,
      picture_url: user.picture_url,
      channel_id: channel[:channel_id]
    }})
  end
end
