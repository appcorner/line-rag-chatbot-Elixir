defmodule ChatServiceWeb.UserSocket do
  use Phoenix.Socket

  channel "chat:*", ChatServiceWeb.ChatChannel
  channel "metrics:*", ChatServiceWeb.MetricsChannel
  channel "traffic:*", ChatServiceWeb.TrafficChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    # Track connection
    ChatService.Telemetry.connection_opened()

    case verify_token(token) do
      {:ok, user_id} ->
        {:ok, assign(socket, :user_id, user_id)}
      {:error, _} ->
        {:ok, socket}
    end
  end

  def connect(_params, socket, _connect_info) do
    # Track connection
    ChatService.Telemetry.connection_opened()
    {:ok, socket}
  end

  @impl true
  def terminate(_reason, _socket) do
    ChatService.Telemetry.connection_closed()
    :ok
  end

  @impl true
  def id(socket) do
    if socket.assigns[:user_id] do
      "user_socket:#{socket.assigns.user_id}"
    else
      nil
    end
  end

  defp verify_token(token) do
    Phoenix.Token.verify(
      ChatServiceWeb.Endpoint,
      "user socket",
      token,
      max_age: 86400
    )
  end
end
