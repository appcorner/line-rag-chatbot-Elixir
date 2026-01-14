defmodule ChatServiceWeb.ConversationsController do
  use ChatServiceWeb, :controller

  alias ChatService.{Messages, Repo}
  alias ChatService.Schemas.{Message, Channel}
  import Ecto.Query

  def index(conn, params) do
    page = Map.get(params, "page", "1") |> String.to_integer()
    per_page = Map.get(params, "per_page", "20") |> String.to_integer()
    offset = (page - 1) * per_page

    conversations =
      Message
      |> group_by([m], [m.channel_id, m.user_id])
      |> select([m], %{channel_id: m.channel_id, user_id: m.user_id, last_at: max(m.inserted_at)})
      |> order_by([m], desc: max(m.inserted_at))
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()
      |> Enum.map(&enrich_conversation_for_frontend/1)

    json(conn, conversations)
  end

  def show(conn, %{"id" => conversation_id}) do
    case parse_conversation_id(conversation_id) do
      {:ok, channel_id, user_id} ->
        messages = get_conversation_messages(channel_id, user_id, 50)
        conversation = enrich_conversation_for_frontend(%{channel_id: channel_id, user_id: user_id})

        json(conn, Map.merge(conversation, %{
          messages: Enum.map(messages, &format_message_for_frontend/1),
          pagination: %{
            page: 1,
            pageSize: 50,
            totalMessages: length(messages),
            totalPages: 1,
            hasMore: false
          }
        }))

      :error ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid conversation ID"})
    end
  end

  def messages(conn, %{"conversation_id" => conversation_id} = params) do
    limit = Map.get(params, "limit", "50") |> String.to_integer()
    before = Map.get(params, "before")

    case parse_conversation_id(conversation_id) do
      {:ok, channel_id, user_id} ->
        messages = get_conversation_messages(channel_id, user_id, limit, before)
        formatted = Enum.map(messages, &format_message_for_frontend/1)

        json(conn, %{
          messages: formatted,
          hasMore: length(messages) >= limit,
          oldestId: List.first(formatted)[:id],
          newestId: List.last(formatted)[:id]
        })

      :error ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid conversation ID"})
    end
  end

  def create_message(conn, %{"conversation_id" => conversation_id} = params) do
    case parse_conversation_id(conversation_id) do
      {:ok, channel_id, user_id} ->
        content = params["content"] || params["text"]

        case Messages.save_outgoing(channel_id, user_id, content) do
          {:ok, message} ->
            conn
            |> put_status(:created)
            |> json(format_message_for_frontend(message))

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: inspect(reason)})
        end

      :error ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid conversation ID"})
    end
  end

  def delete(conn, %{"id" => conversation_id}) do
    case parse_conversation_id(conversation_id) do
      {:ok, channel_id, user_id} ->
        {deleted_count, _} =
          Message
          |> where([m], m.channel_id == ^channel_id and m.user_id == ^user_id)
          |> Repo.delete_all()

        json(conn, %{success: true, deleted: deleted_count})

      :error ->
        conn
        |> put_status(:bad_request)
        |> json(%{success: false, error: "Invalid conversation ID"})
    end
  end

  defp parse_conversation_id(id) do
    case String.split(id, ":") do
      [channel_id, user_id] -> {:ok, channel_id, user_id}
      _ -> :error
    end
  end

  defp enrich_conversation_for_frontend(%{channel_id: channel_id, user_id: user_id}) do
    last_message =
      Message
      |> where([m], m.channel_id == ^channel_id and m.user_id == ^user_id)
      |> order_by([m], desc: m.inserted_at)
      |> limit(1)
      |> Repo.one()

    message_count =
      Message
      |> where([m], m.channel_id == ^channel_id and m.user_id == ^user_id)
      |> Repo.aggregate(:count)

    channel = Repo.get(Channel, channel_id)

    %{
      id: "#{channel_id}:#{user_id}",
      conversationId: "#{channel_id}:#{user_id}",
      userId: user_id,
      userName: nil,
      userAvatar: nil,
      channelId: channel_id,
      channelName: channel && channel.name,
      lastMessage: last_message && last_message.content,
      lastMessageType: (last_message && String.upcase(last_message.message_type || "text")) || "TEXT",
      lastMessageSender: (last_message && direction_to_sender(last_message.direction)) || "USER",
      lastMessageTime: last_message && DateTime.to_iso8601(last_message.inserted_at),
      unreadCount: 0,
      messageCount: message_count
    }
  end

  defp direction_to_sender("incoming"), do: "USER"
  defp direction_to_sender("outgoing"), do: "AI"
  defp direction_to_sender(_), do: "USER"

  defp get_conversation_messages(channel_id, user_id, limit, before \\ nil) do
    query =
      Message
      |> where([m], m.channel_id == ^channel_id and m.user_id == ^user_id)

    query =
      if before do
        {:ok, before_dt, _} = DateTime.from_iso8601(before)
        where(query, [m], m.inserted_at < ^before_dt)
      else
        query
      end

    query
    |> order_by([m], desc: m.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  defp format_message_for_frontend(message) do
    %{
      id: message.id,
      senderType: direction_to_sender(message.direction),
      senderId: message.user_id,
      text: message.content,
      imageUrl: nil,
      timestamp: DateTime.to_iso8601(message.inserted_at),
      messageType: String.upcase(message.message_type || "text"),
      metadata: message.metadata
    }
  end
end
