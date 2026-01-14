defmodule ChatServiceWeb.DashboardController do
  use ChatServiceWeb, :controller

  alias ChatService.Repo
  alias ChatService.Schemas.{Channel, Message}
  import Ecto.Query

  def stats(conn, _params) do
    channels_count = Repo.aggregate(Channel, :count)
    active_channels = Channel |> where([c], c.is_active == true) |> Repo.aggregate(:count)
    messages_count = Repo.aggregate(Message, :count)

    users_count =
      Message
      |> select([m], m.user_id)
      |> distinct(true)
      |> Repo.aggregate(:count)

    conversations_count =
      Message
      |> group_by([m], [m.channel_id, m.user_id])
      |> select([m], count(m.id))
      |> Repo.all()
      |> length()

    json(conn, %{
      messages: %{
        total: messages_count,
        thisWeek: messages_count,
        lastWeek: 0,
        growthPercent: 0
      },
      users: %{
        total: users_count,
        activeThisWeek: users_count,
        activeLastWeek: 0,
        growthPercent: 0
      },
      conversations: %{
        total: conversations_count
      },
      lineOAs: %{
        total: channels_count,
        active: active_channels
      },
      datasets: %{
        total: 0,
        documents: 0,
        embedded: 0
      }
    })
  end

  def recent_activity(conn, params) do
    limit = Map.get(params, "limit", "10") |> String.to_integer()

    activities =
      Message
      |> order_by([m], desc: m.inserted_at)
      |> limit(^limit)
      |> preload([:channel])
      |> Repo.all()
      |> Enum.map(&format_activity_from_message/1)

    json(conn, activities)
  end

  def system_status(conn, _params) do
    redis_status = check_redis()
    db_status = check_database()

    json(conn, %{
      database: db_status,
      redis: redis_status,
      lineApi: "connected",
      llmApi: "connected",
      vectorDb: "connected"
    })
  end

  def datasets(conn, _params) do
    json(conn, [])
  end

  defp format_activity_from_message(message) do
    channel = if Ecto.assoc_loaded?(message.channel), do: message.channel, else: nil

    %{
      id: message.id,
      time: format_time_ago(message.inserted_at),
      timestamp: DateTime.to_iso8601(message.inserted_at),
      user: message.user_id || "Unknown",
      userAvatar: nil,
      message: message.content || "",
      sender: if(message.direction == "incoming", do: "user", else: "bot"),
      channelName: (channel && channel.name) || "Unknown Channel",
      status: "delivered"
    }
  end

  defp format_time_ago(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "#{diff} วินาทีที่แล้ว"
      diff < 3600 -> "#{div(diff, 60)} นาทีที่แล้ว"
      diff < 86400 -> "#{div(diff, 3600)} ชั่วโมงที่แล้ว"
      true -> "#{div(diff, 86400)} วันที่แล้ว"
    end
  end

  defp check_redis do
    case ChatService.Redis.Client.command(["PING"]) do
      {:ok, "PONG"} -> "connected"
      _ -> "disconnected"
    end
  rescue
    _ -> "error"
  end

  defp check_database do
    case Repo.query("SELECT 1") do
      {:ok, _} -> "connected"
      _ -> "disconnected"
    end
  rescue
    _ -> "error"
  end
end
