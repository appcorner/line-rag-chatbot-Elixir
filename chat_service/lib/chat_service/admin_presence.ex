defmodule ChatService.AdminPresence do
  @moduledoc """
  Presence tracking for admins in conversations.
  Tracks which admins are viewing which conversations and their typing status.
  """
  use Phoenix.Presence,
    otp_app: :chat_service,
    pubsub_server: ChatService.PubSub

  @doc """
  Track an admin viewing a conversation.
  """
  def track_admin(pid, topic, admin_id, meta \\ %{}) do
    default_meta = %{
      admin_id: admin_id,
      online_at: System.system_time(:second),
      typing: false,
      name: meta[:name] || "Admin #{admin_id}",
      color: meta[:color] || generate_color(admin_id)
    }

    track(pid, topic, admin_id, Map.merge(default_meta, meta))
  end

  @doc """
  Update admin's typing status.
  """
  def update_typing(pid, topic, admin_id, typing) do
    update(pid, topic, admin_id, fn meta ->
      Map.put(meta, :typing, typing)
    end)
  end

  @doc """
  Get all admins in a conversation topic.
  """
  def list_admins(topic) do
    list(topic)
    |> Enum.map(fn {admin_id, %{metas: metas}} ->
      # Get the most recent meta
      meta = List.first(metas)
      Map.put(meta, :admin_id, admin_id)
    end)
  end

  @doc """
  Get admins who are currently typing.
  """
  def list_typing(topic) do
    list_admins(topic)
    |> Enum.filter(fn admin -> admin.typing end)
  end

  @doc """
  Generate a consistent color for an admin based on their ID.
  """
  def generate_color(admin_id) do
    colors = [
      "#ef4444", # red
      "#f97316", # orange
      "#eab308", # yellow
      "#22c55e", # green
      "#14b8a6", # teal
      "#06b6d4", # cyan
      "#3b82f6", # blue
      "#8b5cf6", # violet
      "#d946ef", # fuchsia
      "#ec4899"  # pink
    ]

    index = :erlang.phash2(admin_id, length(colors))
    Enum.at(colors, index)
  end

  @doc """
  Get the conversation topic name for a user.
  """
  def conversation_topic(user_id, channel_id) do
    "conversation:#{channel_id}:#{user_id}"
  end

  @doc """
  Get the general conversations page topic.
  """
  def conversations_page_topic do
    "conversations:page"
  end
end
