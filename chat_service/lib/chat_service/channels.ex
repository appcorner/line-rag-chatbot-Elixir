defmodule ChatService.Channels do
  @moduledoc """
  Context for managing LINE channels.
  """
  import Ecto.Query, warn: false

  alias ChatService.Repo
  alias ChatService.Schemas.Channel

  @doc """
  Get a channel by channel_id.
  """
  def get_by_channel_id(channel_id) do
    case Repo.get_by(Channel, channel_id: channel_id) do
      nil -> {:error, :not_found}
      channel -> {:ok, channel}
    end
  end

  @doc """
  Get a channel by UUID.
  """
  def get(id) do
    case Repo.get(Channel, id) do
      nil -> {:error, :not_found}
      channel -> {:ok, channel}
    end
  end

  @doc """
  List all active channels.
  """
  def list_active do
    Channel
    |> where([c], c.is_active == true)
    |> order_by([c], asc: c.name)
    |> Repo.all()
  end

  @doc """
  Create a new channel.
  """
  def create(attrs) do
    %Channel{}
    |> Channel.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Update a channel.
  """
  def update_channel(%Channel{} = channel, attrs) do
    result = channel
      |> Channel.changeset(attrs)
      |> Repo.update()

    # Invalidate cache when channel is updated
    case result do
      {:ok, updated} ->
        ChatService.Services.Channel.Service.invalidate_cache(updated.channel_id)
        {:ok, updated}
      error -> error
    end
  end

  @doc """
  Delete a channel.
  """
  def delete(%Channel{} = channel) do
    result = Repo.delete(channel)

    # Invalidate cache when channel is deleted
    case result do
      {:ok, deleted} ->
        ChatService.Services.Channel.Service.invalidate_cache(deleted.channel_id)
        {:ok, deleted}
      error -> error
    end
  end

  @doc """
  Deactivate a channel.
  """
  def deactivate(%Channel{} = channel) do
    update_channel(channel, %{is_active: false})
  end

  @doc """
  Get channel stats.
  """
  def get_stats(channel_id) do
    case get_by_channel_id(channel_id) do
      {:ok, channel} ->
        message_count =
          ChatService.Schemas.Message
          |> where([m], m.channel_id == ^channel.id)
          |> Repo.aggregate(:count)

        webhook_count =
          ChatService.Schemas.WebhookLog
          |> where([w], w.channel_id == ^channel.id)
          |> Repo.aggregate(:count)

        {:ok, %{
          channel: channel,
          message_count: message_count,
          webhook_count: webhook_count
        }}

      error ->
        error
    end
  end
end
