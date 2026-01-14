defmodule ChatServiceWeb.LineOaController do
  use ChatServiceWeb, :controller

  alias ChatService.{Channels, Repo}
  alias ChatService.Schemas.Channel

  def index(conn, _params) do
    channels = Channels.list_active()
    json(conn, Enum.map(channels, &format_channel_for_frontend/1))
  end

  def show(conn, %{"id" => id}) do
    case Repo.get(Channel, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{success: false, error: "LINE OA not found"})

      channel ->
        json(conn, %{success: true, data: format_channel(channel)})
    end
  end

  def create(conn, params) do
    attrs = %{
      channel_id: params["channelId"] || params["channel_id"],
      name: params["name"],
      access_token: params["channelAccessToken"] || params["access_token"],
      channel_secret: params["channelSecret"] || params["channel_secret"],
      is_active: params["enabled"] != false,
      settings: build_settings(params)
    }

    case Channels.create(attrs) do
      {:ok, channel} ->
        conn
        |> put_status(:created)
        |> json(format_channel_for_frontend(channel))

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: format_errors(changeset)})
    end
  end

  defp build_settings(params) do
    %{
      "ai_enabled" => params["aiEnabled"] || false,
      "llm_provider" => params["llmProvider"] || "openai",
      "llm_model" => params["llmModel"] || "gpt-4o-mini",
      "temperature" => params["temperature"] || 0.7,
      "max_tokens" => params["maxTokens"] || 2048,
      "system_prompt" => params["systemPrompt"],
      "message_merge_timeout" => params["messageMergeTimeout"] || 5000,
      "agent_enabled" => params["agentEnabled"] || false,
      "dataset_ids" => params["datasetIds"] || []
    }
  end

  def update(conn, %{"id" => id} = params) do
    case Repo.get(Channel, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{success: false, error: "LINE OA not found"})

      channel ->
        attrs = Map.take(params, ["name", "access_token", "channel_secret", "settings", "is_active"])
        attrs = for {k, v} <- attrs, into: %{}, do: {String.to_existing_atom(k), v}

        case Channels.update_channel(channel, attrs) do
          {:ok, updated} ->
            json(conn, %{success: true, data: format_channel(updated)})

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{success: false, errors: format_errors(changeset)})
        end
    end
  end

  def delete(conn, %{"id" => id}) do
    case Repo.get(Channel, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{success: false, error: "LINE OA not found"})

      channel ->
        case Channels.delete(channel) do
          {:ok, _} ->
            json(conn, %{success: true, message: "LINE OA deleted"})

          {:error, _} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{success: false, error: "Failed to delete"})
        end
    end
  end

  defp format_channel(channel) do
    %{
      id: channel.id,
      channel_id: channel.channel_id,
      name: channel.name,
      access_token: mask_token(channel.access_token),
      channel_secret: mask_token(channel.channel_secret),
      settings: channel.settings,
      is_active: channel.is_active,
      created_at: channel.inserted_at,
      updated_at: channel.updated_at
    }
  end

  defp format_channel_for_frontend(channel) do
    settings = channel.settings || %{}
    %{
      id: channel.id,
      name: channel.name,
      channel_id: channel.channel_id,
      channel_secret: mask_token(channel.channel_secret),
      channel_access_token: mask_token(channel.access_token),
      enabled: channel.is_active,
      ai_enabled: Map.get(settings, "ai_enabled", true),
      llm_provider: Map.get(settings, "llm_provider", "openai"),
      llm_model: Map.get(settings, "llm_model", "gpt-4o"),
      has_llm_api_key: Map.get(settings, "llm_api_key") != nil,
      temperature: Map.get(settings, "temperature", 0.7),
      max_tokens: Map.get(settings, "max_tokens", 1000),
      system_prompt: Map.get(settings, "system_prompt"),
      message_merge_timeout: Map.get(settings, "message_merge_timeout", 2),
      agent_enabled: Map.get(settings, "agent_enabled", false),
      agent_provider: Map.get(settings, "agent_provider", "openai"),
      agent_model: Map.get(settings, "agent_model", "gpt-4o"),
      has_agent_api_key: Map.get(settings, "agent_api_key") != nil,
      agent_skills: Map.get(settings, "agent_skills", "[]"),
      created_at: channel.inserted_at,
      updated_at: channel.updated_at,
      dataset_ids: Map.get(settings, "dataset_ids", []),
      conversation_count: 0,
      message_count: 0
    }
  end

  defp mask_token(nil), do: nil
  defp mask_token(token) when byte_size(token) < 8, do: "****"
  defp mask_token(token) do
    String.slice(token, 0, 4) <> "****" <> String.slice(token, -4, 4)
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
