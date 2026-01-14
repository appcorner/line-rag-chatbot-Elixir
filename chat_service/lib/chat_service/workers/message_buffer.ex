defmodule ChatService.Workers.MessageBuffer do
  @moduledoc false

  use GenServer

  require Logger

  alias ChatService.Services.Ai.Service, as: AiService
  alias ChatService.Services.Line.Client, as: LineClient
  alias ChatService.CircuitBreaker
  alias ChatService.Repo
  alias ChatService.Schemas.Message

  defstruct [
    :channel_id,
    :user_id,
    :channel,
    :timer_ref,
    :reply_token,
    messages: [],
    request_id: nil
  ]

  @doc """
  Add a message to the buffer (map format for WebSocket).
  """
  def add_message(channel_id, user_id, %{} = params) do
    text = params[:text] || params["text"]
    reply_token = params[:reply_token] || params["reply_token"]
    channel = params[:channel] || params["channel"]
    add_message(channel_id, user_id, text, reply_token, channel)
  end

  @doc """
  Add a message to the buffer (explicit params for webhook).
  """
  def add_message(channel_id, user_id, text, reply_token, channel) do
    _buffer_name = via_tuple(channel_id, user_id)

    case Registry.lookup(ChatService.BufferRegistry, {channel_id, user_id}) do
      [{pid, _}] ->
        GenServer.cast(pid, {:add_message, text, reply_token})
        {:ok, pid}

      [] ->
        start_buffer(channel_id, user_id, text, reply_token, channel)
    end
  end

  def start_buffer(channel_id, user_id, text, reply_token, channel) do
    DynamicSupervisor.start_child(
      ChatService.BufferSupervisor,
      {__MODULE__, {channel_id, user_id, text, reply_token, channel}}
    )
  end

  def start_link({channel_id, user_id, text, reply_token, channel}) do
    GenServer.start_link(
      __MODULE__,
      {channel_id, user_id, text, reply_token, channel},
      name: via_tuple(channel_id, user_id)
    )
  end

  def child_spec({channel_id, user_id, _text, _reply_token, _channel} = args) do
    %{
      id: {__MODULE__, channel_id, user_id},
      start: {__MODULE__, :start_link, [args]},
      restart: :temporary
    }
  end

  @impl true
  def init({channel_id, user_id, text, reply_token, channel}) do
    timeout = get_timeout(channel)
    request_id = generate_request_id()
    timer_ref = Process.send_after(self(), {:flush, request_id}, timeout)

    # Save incoming message immediately for real-time display
    save_incoming_message(channel, user_id, text, reply_token)

    state = %__MODULE__{
      channel_id: channel_id,
      user_id: user_id,
      channel: channel,
      messages: [text],
      reply_token: reply_token,
      timer_ref: timer_ref,
      request_id: request_id
    }

    {:ok, state}
  end

  defp save_incoming_message(channel, user_id, text, reply_token) do
    attrs = %{
      user_id: user_id,
      channel_id: channel.id,
      content: text,
      direction: :incoming,
      role: "user",
      reply_token: reply_token,
      is_read: false
    }

    case %Message{} |> Message.changeset(attrs) |> Repo.insert() do
      {:ok, message} ->
        # Broadcast for real-time UI update
        Phoenix.PubSub.broadcast(ChatService.PubSub, "messages", {:message_saved, message})
        message

      {:error, _} ->
        nil
    end
  end

  @impl true
  def handle_cast({:add_message, text, reply_token}, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    # Save additional incoming message immediately
    save_incoming_message(state.channel, state.user_id, text, reply_token)

    timeout = get_timeout(state.channel)
    request_id = generate_request_id()
    timer_ref = Process.send_after(self(), {:flush, request_id}, timeout)

    {:noreply, %{state |
      messages: state.messages ++ [text],
      reply_token: reply_token,
      timer_ref: timer_ref,
      request_id: request_id
    }}
  end

  @impl true
  def handle_info({:flush, request_id}, %{request_id: current_id} = state)
      when request_id != current_id do
    {:noreply, state}
  end

  def handle_info({:flush, _request_id}, state) do
    full_text = Enum.join(state.messages, " ")

    Task.Supervisor.start_child(
      ChatService.TaskSupervisor,
      fn -> process_buffered_message(state, full_text) end
    )

    {:stop, :normal, state}
  end

  defp process_buffered_message(state, text) do
    ChatService.Telemetry.record_message_received()
    start_time = System.monotonic_time(:millisecond)

    Logger.info("[MessageBuffer] Processing message for channel=#{state.channel_id}, user=#{state.user_id}, text=#{String.slice(text, 0, 50)}")
    Logger.info("[MessageBuffer] Channel settings: #{inspect(state.channel.settings)}")

    # Incoming message already saved in init/handle_cast
    # Only process and save the response

    case AiService.process_message(state.channel, state.user_id, text) do
      {:ok, :ai_disabled} ->
        # AI is disabled for this channel - don't send any response
        Logger.info("[MessageBuffer] AI disabled for channel #{state.channel_id}, skipping response")
        duration = System.monotonic_time(:millisecond) - start_time
        ChatService.Telemetry.record_message_processed(duration)

      {:ok, response} ->
        Logger.info("[MessageBuffer] AI response received: #{String.slice(response, 0, 100)}")
        # Save and broadcast outgoing response
        save_and_broadcast_response(state, response)
        send_response(state, response)
        duration = System.monotonic_time(:millisecond) - start_time
        ChatService.Telemetry.record_message_processed(duration)

      {:error, reason} ->
        Logger.error("[MessageBuffer] AI Service error: #{inspect(reason)}")
        ChatService.Telemetry.record_error(:ai_error)
        # Don't send error message to user - just log the error
    end
  end

  defp save_and_broadcast_response(state, content) do
    attrs = %{
      user_id: state.user_id,
      channel_id: state.channel.id,
      content: content,
      direction: :outgoing,
      role: "assistant",
      is_read: true
    }

    case %Message{} |> Message.changeset(attrs) |> Repo.insert() do
      {:ok, message} ->
        Phoenix.PubSub.broadcast(ChatService.PubSub, "messages", {:message_saved, message})
        message

      {:error, changeset} ->
        Logger.error("Failed to save response: #{inspect(changeset.errors)}")
        nil
    end
  end

  defp send_response(state, response) do
    Logger.info("[MessageBuffer] Sending LINE response to user=#{state.user_id}")

    result = CircuitBreaker.call(:line_api, fn ->
      LineClient.reply_message(state.reply_token, state.channel.access_token, response)
    end)

    case result do
      :ok ->
        Logger.info("[MessageBuffer] Reply sent successfully")
        :ok

      {:error, :token_expired} ->
        Logger.warning("[MessageBuffer] Reply token expired, using push_message")
        push_result = CircuitBreaker.call(:line_api, fn ->
          LineClient.push_message(state.user_id, state.channel.access_token, response)
        end)
        Logger.info("[MessageBuffer] Push result: #{inspect(push_result)}")
        push_result

      {:error, reason} ->
        Logger.error("[MessageBuffer] LINE API error: #{inspect(reason)}")
        ChatService.Telemetry.record_error(:line_api_error)
        {:error, reason}
    end
  end

  defp get_timeout(channel) do
    (channel[:message_merge_timeout] || 2) * 1000
  end

  defp generate_request_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16()
  end

  defp via_tuple(channel_id, user_id) do
    {:via, Registry, {ChatService.BufferRegistry, {channel_id, user_id}}}
  end
end
