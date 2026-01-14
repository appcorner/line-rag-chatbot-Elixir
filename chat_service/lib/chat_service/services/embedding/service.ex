defmodule ChatService.Services.Embedding.Service do
  @moduledoc false

  require Logger

  @openai_url "https://api.openai.com/v1/embeddings"
  @google_url "https://generativelanguage.googleapis.com/v1beta/models"

  @doc """
  Generate embedding for text using the specified provider.
  Returns {:ok, [float]} or {:error, reason}
  """
  def embed(text, opts \\ []) do
    provider = Keyword.get(opts, :provider, "openai")
    api_key = Keyword.get(opts, :api_key) || get_default_api_key(provider)
    model = Keyword.get(opts, :model) || default_model(provider)

    # Mask API key for logging
    key_preview = if api_key && String.length(api_key) > 10 do
      String.slice(api_key, 0, 10) <> "..."
    else
      "nil"
    end
    Logger.info("[EmbeddingService] embed: provider=#{provider}, model=#{model}, key=#{key_preview}, text_len=#{String.length(text)}")

    if is_nil(api_key) or api_key == "" do
      Logger.error("[EmbeddingService] No API key for #{provider}")
      {:error, "No API key configured for #{provider}"}
    else
      result = case provider do
        "openai" -> embed_openai(text, model, api_key)
        "google" -> embed_google(text, model, api_key)
        _ -> {:error, "Unsupported provider: #{provider}"}
      end

      case result do
        {:ok, _} -> Logger.info("[EmbeddingService] embed success")
        {:error, reason} -> Logger.error("[EmbeddingService] embed failed: #{inspect(reason)}")
      end

      result
    end
  end

  @doc """
  Generate embeddings for multiple texts (batch).
  """
  def embed_batch(texts, opts \\ []) when is_list(texts) do
    provider = Keyword.get(opts, :provider, "openai")
    api_key = Keyword.get(opts, :api_key) || get_default_api_key(provider)
    model = Keyword.get(opts, :model) || default_model(provider)

    if is_nil(api_key) or api_key == "" do
      {:error, "No API key configured for #{provider}"}
    else
      case provider do
        "openai" -> embed_batch_openai(texts, model, api_key)
        "google" -> embed_batch_google(texts, model, api_key)
        _ -> {:error, "Unsupported provider: #{provider}"}
      end
    end
  end

  @doc """
  Get embedding dimension for a model.
  """
  def dimension(provider \\ "openai", model \\ nil) do
    case {provider, model || default_model(provider)} do
      {"openai", "text-embedding-3-small"} -> 1536
      {"openai", "text-embedding-3-large"} -> 3072
      {"openai", "text-embedding-ada-002"} -> 1536
      {"google", "text-embedding-004"} -> 768
      {"google", _} -> 768
      _ -> 1536
    end
  end

  # OpenAI Implementation

  defp embed_openai(text, model, api_key) do
    body = %{
      model: model,
      input: text
    }

    case do_openai_request(body, api_key) do
      {:ok, %{"data" => [%{"embedding" => embedding} | _]}} ->
        {:ok, embedding}

      {:ok, resp} ->
        Logger.error("[EmbeddingService] Unexpected OpenAI response: #{inspect(resp)}")
        {:error, "Unexpected response format"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp embed_batch_openai(texts, model, api_key) do
    body = %{
      model: model,
      input: texts
    }

    case do_openai_request(body, api_key) do
      {:ok, %{"data" => data}} ->
        embeddings =
          data
          |> Enum.sort_by(& &1["index"])
          |> Enum.map(& &1["embedding"])

        {:ok, embeddings}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_openai_request(body, api_key) do
    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    request = Finch.build(:post, @openai_url, headers, Jason.encode!(body))

    # Retry up to 2 times on timeout
    do_request_with_retry(request, 2)
  end

  defp do_request_with_retry(request, retries_left) do
    case Finch.request(request, ChatService.Finch, receive_timeout: 30_000) do
      {:ok, %Finch.Response{status: 200, body: resp_body}} ->
        {:ok, Jason.decode!(resp_body)}

      {:ok, %Finch.Response{status: 429, body: resp_body}} ->
        # Rate limited - wait and retry
        if retries_left > 0 do
          Logger.warning("[EmbeddingService] Rate limited, waiting 2s and retrying...")
          Process.sleep(2000)
          do_request_with_retry(request, retries_left - 1)
        else
          Logger.error("[EmbeddingService] Rate limited: #{resp_body}")
          {:error, "Rate limited - please try again later"}
        end

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        Logger.error("[EmbeddingService] OpenAI error #{status}: #{resp_body}")
        {:error, "API error: #{status}"}

      {:error, %Mint.TransportError{reason: :timeout}} ->
        if retries_left > 0 do
          Logger.warning("[EmbeddingService] Timeout, retrying (#{retries_left} left)...")
          do_request_with_retry(request, retries_left - 1)
        else
          Logger.error("[EmbeddingService] Request timeout after retries")
          {:error, "Connection timeout - please check your network"}
        end

      {:error, reason} ->
        Logger.error("[EmbeddingService] Request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Google Implementation

  defp embed_google(text, model, api_key) do
    url = "#{@google_url}/#{model}:embedContent?key=#{api_key}"

    body = %{
      model: "models/#{model}",
      content: %{
        parts: [%{text: text}]
      }
    }

    case do_google_request(url, body) do
      {:ok, %{"embedding" => %{"values" => values}}} ->
        {:ok, values}

      {:ok, resp} ->
        Logger.error("[EmbeddingService] Unexpected Google response: #{inspect(resp)}")
        {:error, "Unexpected response format"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp embed_batch_google(texts, model, api_key) do
    url = "#{@google_url}/#{model}:batchEmbedContents?key=#{api_key}"

    requests =
      Enum.map(texts, fn text ->
        %{
          model: "models/#{model}",
          content: %{parts: [%{text: text}]}
        }
      end)

    body = %{requests: requests}

    case do_google_request(url, body) do
      {:ok, %{"embeddings" => embeddings}} ->
        values = Enum.map(embeddings, & &1["values"])
        {:ok, values}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_google_request(url, body) do
    headers = [{"Content-Type", "application/json"}]
    request = Finch.build(:post, url, headers, Jason.encode!(body))

    case Finch.request(request, ChatService.Finch, receive_timeout: 60_000) do
      {:ok, %Finch.Response{status: 200, body: resp_body}} ->
        {:ok, Jason.decode!(resp_body)}

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        Logger.error("[EmbeddingService] Google error #{status}: #{resp_body}")
        {:error, "API error: #{status}"}

      {:error, reason} ->
        Logger.error("[EmbeddingService] Request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Helpers

  defp default_model("openai"), do: "text-embedding-3-small"
  defp default_model("google"), do: "text-embedding-004"
  defp default_model(_), do: "text-embedding-3-small"

  defp get_default_api_key("openai") do
    Application.get_env(:chat_service, :openai_api_key) ||
      System.get_env("OPENAI_API_KEY")
  end

  defp get_default_api_key("google") do
    Application.get_env(:chat_service, :google_api_key) ||
      System.get_env("GOOGLE_API_KEY")
  end

  defp get_default_api_key(_), do: nil
end
