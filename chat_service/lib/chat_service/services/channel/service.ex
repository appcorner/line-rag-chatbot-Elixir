defmodule ChatService.Services.Channel.Service do
  @moduledoc false

  require Logger

  alias ChatService.Repo
  alias ChatService.Schemas.Channel
  import Ecto.Query

  @cache_table :channel_cache
  @cache_ttl 300_000

  def init_cache do
    :ets.new(@cache_table, [:named_table, :set, :public, read_concurrency: true])
  end

  def get_channel(channel_id) do
    case get_from_cache(channel_id) do
      {:ok, channel} ->
        {:ok, channel}

      :not_found ->
        fetch_and_cache(channel_id)
    end
  end

  def invalidate_cache(channel_id) do
    try do
      :ets.delete(@cache_table, channel_id)
      :ok
    rescue
      ArgumentError -> :ok  # Table doesn't exist yet, nothing to invalidate
    end
  end

  def invalidate_all do
    try do
      :ets.delete_all_objects(@cache_table)
      :ok
    rescue
      ArgumentError -> :ok  # Table doesn't exist yet
    end
  end

  defp get_from_cache(channel_id) do
    case :ets.lookup(@cache_table, channel_id) do
      [{^channel_id, channel, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, channel}
        else
          :ets.delete(@cache_table, channel_id)
          :not_found
        end

      [] ->
        :not_found
    end
  rescue
    ArgumentError ->
      init_cache()
      :not_found
  end

  defp fetch_and_cache(channel_id) do
    case fetch_from_database(channel_id) do
      {:ok, channel} ->
        if channel.is_active do
          expires_at = System.monotonic_time(:millisecond) + @cache_ttl
          :ets.insert(@cache_table, {channel_id, channel, expires_at})
          {:ok, channel}
        else
          {:error, :channel_not_found}
        end

      {:error, :not_found} ->
        {:error, :channel_not_found}

      {:error, reason} ->
        Logger.error("Failed to fetch channel: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fetch_from_database(channel_id) do
    case Channel |> where([c], c.channel_id == ^channel_id) |> Repo.one() do
      nil ->
        {:error, :not_found}

      channel ->
        {:ok, normalize_channel(channel)}
    end
  rescue
    e ->
      Logger.error("Database error: #{inspect(e)}")
      {:error, :database_error}
  end

  defp normalize_channel(%Channel{} = channel) do
    settings = channel.settings || %{}

    %{
      id: channel.id,
      name: channel.name,
      channel_id: channel.channel_id,
      channel_secret: channel.channel_secret,
      access_token: channel.access_token,
      is_active: channel.is_active,
      dataset_id: channel.dataset_id,
      settings: settings,  # Keep raw settings for AI service
      # Flatten common settings for quick access
      ai_enabled: settings["ai_enabled"] != false,
      llm_provider: settings["llm_provider"] || "openai",
      llm_model: settings["llm_model"] || "gpt-4o-mini",
      llm_api_key: settings["llm_api_key"],
      temperature: settings["temperature"] || 0.7,
      max_tokens: settings["max_tokens"] || 2048,
      system_prompt: settings["system_prompt"] || "",
      agent_enabled: settings["agent_enabled"] || false,
      agent_skills: settings["agent_skills"] || [],
      message_merge_timeout: settings["message_merge_timeout"] || 2
    }
  end
end
