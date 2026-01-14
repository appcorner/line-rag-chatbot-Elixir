defmodule ChatServiceWeb.ChatChannel do
  use ChatServiceWeb, :channel

  @impl true
  def join("chat:" <> channel_id, _params, socket) do
    case ChatService.Services.Channel.Service.get_channel(channel_id) do
      {:ok, _channel} ->
        send(self(), :after_join)
        {:ok, assign(socket, :channel_id, channel_id)}
      {:error, _} ->
        {:error, %{reason: "channel_not_found"}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    push(socket, "presence_state", %{})
    {:noreply, socket}
  end

  @impl true
  def handle_in("message", %{"text" => text} = payload, socket) do
    channel_id = socket.assigns.channel_id
    user_id = socket.assigns[:user_id] || "anonymous"

    ChatService.Workers.MessageBuffer.add_message(channel_id, user_id, %{
      text: text,
      reply_token: nil,
      channel: nil,
      socket_ref: make_ref()
    })

    broadcast!(socket, "message", %{
      user_id: user_id,
      text: text,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })

    {:noreply, socket}
  end

  def handle_in("typing", _payload, socket) do
    user_id = socket.assigns[:user_id] || "anonymous"
    broadcast_from!(socket, "typing", %{user_id: user_id})
    {:noreply, socket}
  end
end
