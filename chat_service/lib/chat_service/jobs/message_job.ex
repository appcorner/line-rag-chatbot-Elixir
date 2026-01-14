defmodule ChatService.Jobs.MessageJob do
  @moduledoc """
  Oban job for processing messages to backend AI.
  Handles the heavy lifting of:
  - Calling backend AI service
  - Saving responses to database
  - Sending replies via LINE API
  """
  use Oban.Worker,
    queue: :messages,
    max_attempts: 3,
    priority: 1

  require Logger

  alias ChatService.Services.Ai.Service, as: AiService
  alias ChatService.Services.Line.Client, as: LineClient
  alias ChatService.CircuitBreaker
  alias ChatService.Repo
  alias ChatService.Schemas.Message

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    %{
      "channel_id" => channel_id,
      "user_id" => user_id,
      "text" => text,
      "reply_token" => reply_token,
      "channel" => channel
    } = args

    channel = atomize_keys(channel)

    ChatService.Telemetry.record_message_received()
    start_time = System.monotonic_time(:millisecond)

    case AiService.process_message(channel, user_id, text) do
      {:ok, :ai_disabled} ->
        # AI is disabled for this channel - don't send any response
        Logger.info("AI disabled for channel #{channel[:id]}, skipping response")
        duration = System.monotonic_time(:millisecond) - start_time
        ChatService.Telemetry.record_message_processed(duration)
        :ok

      {:ok, response} ->
        save_and_broadcast_response(user_id, channel, response)
        send_response(reply_token, user_id, channel, response)
        duration = System.monotonic_time(:millisecond) - start_time
        ChatService.Telemetry.record_message_processed(duration)
        :ok

      {:error, reason} ->
        Logger.error("AI Service error for job: #{inspect(reason)}")
        ChatService.Telemetry.record_error(:ai_error)


        {:error, reason}
    end
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

  defp save_and_broadcast_response(user_id, channel, content) do
    attrs = %{
      user_id: user_id,
      channel_id: channel[:id],
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

  defp send_response(reply_token, user_id, channel, response) do
    case CircuitBreaker.call(:line_api, fn ->
      LineClient.reply_message(reply_token, channel[:access_token], response)
    end) do
      :ok ->
        :ok

      {:error, :token_expired} ->
        CircuitBreaker.call(:line_api, fn ->
          LineClient.push_message(user_id, channel[:access_token], response)
        end)

      {:error, _reason} ->
        ChatService.Telemetry.record_error(:line_api_error)
    end
  end

end
