defmodule ChatServiceWeb.WebhookController do
  use ChatServiceWeb, :controller
  require Logger

  alias ChatService.Jobs.WebhookJob

  @dedup_table :webhook_dedup_web
  @dedup_ttl_ms 60_000

  def handle(conn, %{"channel_id" => channel_id}) do
    with {:ok, channel} <- get_channel(channel_id),
         :ok <- verify_signature(conn, channel),
         {:ok, body} <- get_body(conn),
         {:ok, events} <- parse_events(body) do

      unique_events = deduplicate_events(events)
      Logger.info("[Webhook] Received #{length(events)} events, #{length(unique_events)} unique")

      enqueue_events(unique_events, channel)

      json(conn, %{status: "ok"})
    else
      {:error, :channel_not_found} ->
        conn |> put_status(404) |> json(%{error: "channel_not_found"})
      {:error, :invalid_signature} ->
        conn |> put_status(401) |> json(%{error: "invalid_signature"})
      {:error, reason} ->
        Logger.error("Webhook error: #{inspect(reason)}")
        conn |> put_status(400) |> json(%{error: "bad_request"})
    end
  end

  defp init_dedup_table do
    if :ets.whereis(@dedup_table) == :undefined do
      :ets.new(@dedup_table, [:set, :public, :named_table])
    end
    :ok
  end

  defp deduplicate_events(events) do
    init_dedup_table()
    now = System.monotonic_time(:millisecond)

    Enum.filter(events, fn event ->
      event_id = event["webhookEventId"]

      if is_nil(event_id) do
        true
      else
        case :ets.lookup(@dedup_table, event_id) do
          [{^event_id, _timestamp}] ->
            Logger.warning("[Webhook] Duplicate event filtered: #{event_id}")
            false

          [] ->
            :ets.insert(@dedup_table, {event_id, now})
            spawn(fn -> cleanup_old_entries(now) end)
            true
        end
      end
    end)
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

  defp enqueue_events(events, channel) do
    case Application.get_env(:chat_service, :queue_mode, :oban) do
      :rabbitmq -> enqueue_to_rabbitmq(events, channel)
      _ -> enqueue_to_oban(events, channel)
    end
  end

  defp enqueue_to_oban(events, channel) do
    channel_map = %{
      "id" => channel.id,
      "channel_id" => channel.channel_id,
      "access_token" => channel.access_token,
      "name" => channel.name,
      "settings" => channel.settings || %{},
      "dataset_id" => channel.dataset_id
    }

    Enum.each(events, fn event ->
      %{"event" => event, "channel" => channel_map}
      |> WebhookJob.new()
      |> Oban.insert()
    end)
  end

  defp enqueue_to_rabbitmq(events, channel) do
    alias ChatService.Pipelines.WebhookPipeline

    Enum.each(events, fn event ->
      WebhookPipeline.publish(event, channel)
    end)
  end

  defp get_channel(channel_id) do
    case ChatService.Services.Channel.Service.get_channel(channel_id) do
      {:ok, channel} -> {:ok, channel}
      _ -> {:error, :channel_not_found}
    end
  end

  defp verify_signature(conn, channel) do
    raw_body = conn.assigns[:raw_body] || ""
    signature = get_req_header(conn, "x-line-signature") |> List.first() || ""

    expected =
      :crypto.mac(:hmac, :sha256, channel.channel_secret, raw_body)
      |> Base.encode64()

    if Plug.Crypto.secure_compare(signature, expected) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp get_body(conn) do
    case conn.assigns[:raw_body] do
      nil -> {:error, :no_body}
      body -> {:ok, body}
    end
  end

  defp parse_events(body) do
    case Jason.decode(body) do
      {:ok, %{"events" => events}} -> {:ok, events}
      _ -> {:error, :invalid_json}
    end
  end
end
