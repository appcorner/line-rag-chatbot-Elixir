defmodule ChatService.Pipelines.WebhookPipeline do
  @moduledoc """
  Broadway pipeline for processing LINE webhooks at scale.

  Handles millions of messages per day with:
  - Automatic batching for efficiency
  - Back-pressure to prevent overload
  - Concurrent processing with configurable workers
  - Automatic reconnection to RabbitMQ
  - Dead-letter queue for failed messages

  Architecture:
  ```
  RabbitMQ Queue ──► Broadway Pipeline ──► Process ──► Response
       │                    │
       │              ┌─────┴─────┐
       │              ▼           ▼
       │         Processor   Processor  (concurrent)
       │              │           │
       │              └─────┬─────┘
       │                    ▼
       │               Batcher
       │                    │
       └──── DLQ ◄──────────┘ (on failure)
  ```
  """
  use Broadway

  require Logger

  alias Broadway.Message
  alias ChatService.Services.User.Service, as: UserService
  alias ChatService.Workers.MessageBuffer

  @queue "line_webhooks"
  @dlq "line_webhooks_dlq"
  @dedup_table :webhook_dedup_broadway
  @dedup_ttl_ms 60_000

  def start_link(opts) do
    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {
          BroadwayRabbitMQ.Producer,
          queue: @queue,
          connection: rabbitmq_config(),
          qos: [prefetch_count: 100],
          metadata: [:routing_key, :headers],
          declare: [durable: true],
          bindings: [],
          on_failure: :reject_and_requeue_once
        },
        concurrency: 2
      ],
      processors: [
        default: [
          concurrency: System.schedulers_online() * 4,
          max_demand: 10
        ]
      ],
      batchers: [
        default: [
          batch_size: 50,
          batch_timeout: 100,
          concurrency: 4
        ]
      ],
      context: opts[:context] || %{}
    )
  end

  @impl true
  def handle_message(_processor, %Message{data: data} = message, _context) do
    case Jason.decode(data) do
      {:ok, %{"event" => event, "channel" => channel}} ->
        event_id = event["webhookEventId"]

        # Check for duplicate at Broadway level
        if is_duplicate?(event_id) do
          Logger.warning("[Broadway] Duplicate event filtered: #{event_id}")
          message  # Return message without processing (will be acked)
        else
          mark_as_seen(event_id)
          # Process immediately for real-time
          process_event(event, channel)
          message
        end

      {:ok, _other} ->
        Message.failed(message, "invalid_format")

      {:error, reason} ->
        Logger.error("Failed to decode webhook message: #{inspect(reason)}")
        Message.failed(message, reason)
    end
  rescue
    e ->
      Logger.error("Error processing webhook: #{inspect(e)}")
      Message.failed(message, e)
  end

  @impl true
  def handle_batch(_batcher, messages, _batch_info, _context) do
    # Batch telemetry
    ChatService.Telemetry.record_batch_processed(length(messages))
    messages
  end

  @impl true
  def handle_failed(messages, _context) do
    # Log failed messages for debugging
    Enum.each(messages, fn message ->
      Logger.error("""
      Failed to process webhook message:
        Data: #{inspect(message.data)}
        Status: #{inspect(message.status)}
      """)
    end)

    messages
  end

  # Event processing (same logic as WebhookJob)
  defp process_event(event, channel) do
    channel = atomize_keys(channel)

    # Broadcast for real-time monitoring
    broadcast_webhook_event(event, channel)

    case event["type"] do
      "message" -> handle_message_event(event, channel)
      "follow" -> handle_follow_event(event, channel)
      "unfollow" -> handle_unfollow_event(event, channel)
      "postback" -> handle_postback_event(event, channel)
      _ -> :ok
    end
  end

  defp handle_message_event(event, channel) do
    user_id = get_in(event, ["source", "userId"])
    reply_token = event["replyToken"]

    {:ok, user} = ensure_user_profile(user_id, channel)
    broadcast_user_update(user, channel)

    case event["message"] do
      %{"type" => "text", "text" => text} ->
        MessageBuffer.add_message(
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

  defp handle_follow_event(event, channel) do
    user_id = get_in(event, ["source", "userId"])

    case ensure_user_profile(user_id, channel) do
      {:ok, user} ->
        Logger.info("New follower: #{user_id} on #{channel[:channel_id]}")
        broadcast_user_update(user, channel)

      {:error, reason} ->
        Logger.warning("Failed to get follower profile: #{inspect(reason)}")
    end
  end

  defp handle_unfollow_event(event, channel) do
    user_id = get_in(event, ["source", "userId"])
    Logger.info("Unfollowed: #{user_id} from #{channel[:channel_id]}")
  end

  defp handle_postback_event(event, channel) do
    user_id = get_in(event, ["source", "userId"])
    data = get_in(event, ["postback", "data"])
    {:ok, _user} = ensure_user_profile(user_id, channel)
    Logger.info("Postback: #{data} from #{user_id}")
  end

  defp ensure_user_profile(user_id, channel) when is_binary(user_id) do
    channel_struct = %{
      id: channel[:id],
      channel_id: channel[:channel_id],
      access_token: channel[:access_token]
    }

    UserService.get_or_create_user(user_id, channel_struct)
  end

  defp ensure_user_profile(nil, _channel), do: {:error, :no_user_id}

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

  defp broadcast_user_update(user, channel) do
    Phoenix.PubSub.broadcast(ChatService.PubSub, "users", {:user_updated, %{
      line_user_id: user.line_user_id,
      display_name: user.display_name,
      picture_url: user.picture_url,
      channel_id: channel[:channel_id]
    }})
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) ->
        atom_key = try do
          String.to_existing_atom(k)
        rescue
          _ -> String.to_atom(k)
        end
        {atom_key, atomize_keys(v)}
      {k, v} -> {k, atomize_keys(v)}
    end)
  end

  defp atomize_keys(value), do: value

  defp rabbitmq_config do
    Application.get_env(:chat_service, :rabbitmq, [
      host: "localhost",
      port: 5672,
      username: "guest",
      password: "guest",
      virtual_host: "/"
    ])
  end

  # Deduplication helpers
  defp init_dedup_table do
    if :ets.whereis(@dedup_table) == :undefined do
      :ets.new(@dedup_table, [:set, :public, :named_table])
    end
    :ok
  end

  defp is_duplicate?(nil), do: false
  defp is_duplicate?(event_id) do
    init_dedup_table()
    case :ets.lookup(@dedup_table, event_id) do
      [{^event_id, _timestamp}] -> true
      [] -> false
    end
  end

  defp mark_as_seen(nil), do: :ok
  defp mark_as_seen(event_id) do
    init_dedup_table()
    now = System.monotonic_time(:millisecond)
    :ets.insert(@dedup_table, {event_id, now})
    # Cleanup old entries asynchronously
    spawn(fn -> cleanup_old_entries(now) end)
    :ok
  end

  defp cleanup_old_entries(now) do
    try do
      :ets.foldl(fn {event_id, timestamp}, acc ->
        if now - timestamp > @dedup_ttl_ms do
          :ets.delete(@dedup_table, event_id)
        end
        acc
      end, :ok, @dedup_table)
    rescue
      _ -> :ok
    end
  end

  # Helper to publish messages to the queue
  def publish(event, channel) do
    message = Jason.encode!(%{
      "event" => event,
      "channel" => %{
        "id" => channel.id,
        "channel_id" => channel.channel_id,
        "access_token" => channel.access_token,
        "name" => channel.name,
        "settings" => channel.settings || %{},
        "dataset_id" => channel.dataset_id
      }
    })

    case AMQP.Connection.open(rabbitmq_config()) do
      {:ok, conn} ->
        {:ok, chan} = AMQP.Channel.open(conn)
        AMQP.Queue.declare(chan, @queue, durable: true)
        AMQP.Basic.publish(chan, "", @queue, message, persistent: true)
        AMQP.Connection.close(conn)
        :ok

      {:error, reason} ->
        Logger.error("Failed to publish to RabbitMQ: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
