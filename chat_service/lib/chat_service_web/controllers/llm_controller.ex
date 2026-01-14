defmodule ChatServiceWeb.LlmController do
  use ChatServiceWeb, :controller

  @providers [
    %{
      id: "openai",
      name: "OpenAI",
      models: [
        %{id: "gpt-4o", name: "GPT-4o", maxTokens: 128000, inputPrice: 2.5, outputPrice: 10.0},
        %{id: "gpt-4o-mini", name: "GPT-4o Mini", maxTokens: 128000, inputPrice: 0.15, outputPrice: 0.6},
        %{id: "gpt-4-turbo", name: "GPT-4 Turbo", maxTokens: 128000, inputPrice: 10.0, outputPrice: 30.0},
        %{id: "gpt-3.5-turbo", name: "GPT-3.5 Turbo", maxTokens: 16385, inputPrice: 0.5, outputPrice: 1.5}
      ],
      embeddingModels: [
        %{id: "text-embedding-3-small", name: "Text Embedding 3 Small", dimension: 1536, price: 0.02},
        %{id: "text-embedding-3-large", name: "Text Embedding 3 Large", dimension: 3072, price: 0.13},
        %{id: "text-embedding-ada-002", name: "Ada 002", dimension: 1536, price: 0.1}
      ]
    },
    %{
      id: "anthropic",
      name: "Anthropic",
      models: [
        %{id: "claude-3-5-sonnet-20241022", name: "Claude 3.5 Sonnet", maxTokens: 200000, inputPrice: 3.0, outputPrice: 15.0},
        %{id: "claude-3-5-haiku-20241022", name: "Claude 3.5 Haiku", maxTokens: 200000, inputPrice: 1.0, outputPrice: 5.0},
        %{id: "claude-3-opus-20240229", name: "Claude 3 Opus", maxTokens: 200000, inputPrice: 15.0, outputPrice: 75.0}
      ],
      embeddingModels: []
    },
    %{
      id: "google",
      name: "Google AI",
      models: [
        %{id: "gemini-1.5-pro", name: "Gemini 1.5 Pro", maxTokens: 2000000, inputPrice: 1.25, outputPrice: 5.0},
        %{id: "gemini-1.5-flash", name: "Gemini 1.5 Flash", maxTokens: 1000000, inputPrice: 0.075, outputPrice: 0.3},
        %{id: "gemini-2.0-flash-exp", name: "Gemini 2.0 Flash", maxTokens: 1000000, inputPrice: 0.0, outputPrice: 0.0}
      ],
      embeddingModels: [
        %{id: "text-embedding-004", name: "Text Embedding 004", dimension: 768, price: 0.0}
      ]
    },
    %{
      id: "ollama",
      name: "Ollama (Local)",
      models: [
        %{id: "llama3.2", name: "Llama 3.2", maxTokens: 128000, inputPrice: 0.0, outputPrice: 0.0},
        %{id: "llama3.1", name: "Llama 3.1", maxTokens: 128000, inputPrice: 0.0, outputPrice: 0.0},
        %{id: "mistral", name: "Mistral", maxTokens: 32000, inputPrice: 0.0, outputPrice: 0.0},
        %{id: "qwen2.5", name: "Qwen 2.5", maxTokens: 128000, inputPrice: 0.0, outputPrice: 0.0}
      ],
      embeddingModels: [
        %{id: "nomic-embed-text", name: "Nomic Embed Text", dimension: 768, price: 0.0},
        %{id: "mxbai-embed-large", name: "MXBai Embed Large", dimension: 1024, price: 0.0}
      ]
    },
    %{
      id: "groq",
      name: "Groq",
      models: [
        %{id: "llama-3.3-70b-versatile", name: "Llama 3.3 70B", maxTokens: 128000, inputPrice: 0.59, outputPrice: 0.79},
        %{id: "llama-3.1-8b-instant", name: "Llama 3.1 8B", maxTokens: 128000, inputPrice: 0.05, outputPrice: 0.08},
        %{id: "mixtral-8x7b-32768", name: "Mixtral 8x7B", maxTokens: 32768, inputPrice: 0.24, outputPrice: 0.24}
      ],
      embeddingModels: []
    }
  ]

  def providers(conn, _params) do
    json(conn, @providers)
  end

  def models(conn, %{"provider" => provider_id} = params) do
    case Enum.find(@providers, fn p -> p.id == provider_id end) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Provider not found"})

      provider ->
        model_type = params["type"] || "llm"
        models = if model_type == "embedding", do: provider.embeddingModels, else: provider.models

        json(conn, %{models: models})
    end
  end

  def embedding_models(conn, %{"provider" => provider_id}) do
    case Enum.find(@providers, fn p -> p.id == provider_id end) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Provider not found"})

      provider ->
        json(conn, %{models: provider.embeddingModels})
    end
  end

  def chat(conn, params) do
    provider = params["provider"] || "openai"
    model = params["model"] || "gpt-4o-mini"

    json(conn, %{
      id: Ecto.UUID.generate(),
      provider: provider,
      model: model,
      message: %{
        role: "assistant",
        content: "This is a placeholder response. LLM integration is not yet implemented."
      },
      usage: %{
        prompt_tokens: 0,
        completion_tokens: 0,
        total_tokens: 0
      }
    })
  end

  def embed(conn, params) do
    provider = params["provider"] || "openai"
    model = params["model"] || "text-embedding-3-small"

    json(conn, %{
      provider: provider,
      model: model,
      embedding: [],
      dimension: 1536,
      usage: %{
        total_tokens: 0
      }
    })
  end
end
