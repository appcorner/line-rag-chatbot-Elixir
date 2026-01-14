defmodule ChatService.Messages do
  @moduledoc """
  Context for managing chat messages.
  """
  import Ecto.Query

  alias ChatService.Repo
  alias ChatService.Schemas.{Message, Channel}

  @doc """
  Save an incoming message.
  """
  def save_incoming(channel_id, user_id, content, opts \\ []) do
    save_message(channel_id, user_id, content, :incoming, opts)
  end

  @doc """
  Save an outgoing message.
  """
  def save_outgoing(channel_id, user_id, content, opts \\ []) do
    save_message(channel_id, user_id, content, :outgoing, opts)
  end

  @doc """
  Get recent messages for a channel and user.
  """
  def get_recent(channel_id, user_id, limit \\ 50) do
    case get_channel_uuid(channel_id) do
      {:ok, channel_uuid} ->
        messages =
          Message
          |> where([m], m.channel_id == ^channel_uuid and m.user_id == ^user_id)
          |> order_by([m], desc: m.inserted_at)
          |> limit(^limit)
          |> Repo.all()
          |> Enum.reverse()

        {:ok, messages}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Get message count for a channel.
  """
  def count_by_channel(channel_id) do
    case get_channel_uuid(channel_id) do
      {:ok, channel_uuid} ->
        count =
          Message
          |> where([m], m.channel_id == ^channel_uuid)
          |> Repo.aggregate(:count)

        {:ok, count}

      {:error, _} = error ->
        error
    end
  end

  # Private functions

  defp save_message(channel_id, user_id, content, direction, opts) do
    case get_channel_uuid(channel_id) do
      {:ok, channel_uuid} ->
        attrs = %{
          channel_id: channel_uuid,
          user_id: user_id,
          content: content,
          direction: direction,
          message_type: Keyword.get(opts, :message_type, "text"),
          reply_token: Keyword.get(opts, :reply_token),
          line_message_id: Keyword.get(opts, :line_message_id),
          metadata: Keyword.get(opts, :metadata, %{})
        }

        %Message{}
        |> Message.changeset(attrs)
        |> Repo.insert()

      {:error, _} = error ->
        error
    end
  end

  defp get_channel_uuid(channel_id) do
    case Repo.get_by(Channel, channel_id: channel_id) do
      nil -> {:error, :channel_not_found}
      channel -> {:ok, channel.id}
    end
  end
end
