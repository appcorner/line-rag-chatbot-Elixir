defmodule ChatService.Agents.Tools.FaqSearch do
  @moduledoc """
  Tool for searching FAQ documents using vector similarity.
  Searches the dataset for relevant FAQ answers using embeddings.
  """

  @behaviour ChatService.Agents.Tool

  require Logger

  alias ChatService.Repo
  alias ChatService.Schemas.Dataset
  import Ecto.Query
  alias ChatService.Services.Embedding.Service, as: EmbeddingService
  alias ChatService.VectorService.Client, as: VectorClient

  @impl true
  def name, do: "search_faq"

  @impl true
  def definition do
    %{
      name: name(),
      description: "ค้นหาคำตอบจากฐานข้อมูล FAQ โดยใช้ความหมายของคำถาม (semantic search) - ใช้เมื่อผู้ใช้ถามคำถามที่อาจมีคำตอบในระบบ",
      parameters: %{
        type: "object",
        properties: %{
          query: %{
            type: "string",
            description: "คำถามหรือข้อความที่ต้องการค้นหา"
          },
          collection_name: %{
            type: "string",
            description: "ชื่อ collection ของ dataset ที่ต้องการค้นหา (ถ้าไม่ระบุจะใช้ default)"
          },
          top_k: %{
            type: "integer",
            description: "จำนวนผลลัพธ์ที่ต้องการ (default: 3)"
          }
        },
        required: ["query"]
      }
    }
  end

  @impl true
  def enabled?, do: true

  @impl true
  def execute(params) do
    query = params["query"] || params[:query]
    collection_name = params["collection_name"] || params[:collection_name]
    top_k = params["top_k"] || params[:top_k] || 3

    Logger.info("[FaqSearch] Searching FAQ: query=#{inspect(query)}, collection=#{inspect(collection_name)}, top_k=#{top_k}")

    if is_nil(query) or query == "" do
      {:error, "Query is required"}
    else
      search_faq(query, collection_name, top_k)
    end
  end

  defp search_faq(query, collection_name, top_k) do
    # Get dataset/collection info
    {collection, embedding_opts} = get_collection_info(collection_name)

    if is_nil(collection) do
      {:error, "No FAQ dataset configured or found"}
    else
      # Generate embedding for query
      case EmbeddingService.embed(query, embedding_opts) do
        {:ok, embedding} ->
          # Search vector database
          case VectorClient.search(collection, embedding, top_k) do
            {:ok, %{"results" => results}} when results != [] ->
              format_results(results)

            {:ok, _} ->
              {:ok, "ไม่พบคำตอบที่เกี่ยวข้องในฐานข้อมูล FAQ"}

            {:error, reason} ->
              Logger.error("[FaqSearch] Vector search failed: #{inspect(reason)}")
              {:error, "Search failed: #{inspect(reason)}"}
          end

        {:error, reason} ->
          Logger.error("[FaqSearch] Embedding failed: #{inspect(reason)}")
          {:error, "Failed to process query: #{inspect(reason)}"}
      end
    end
  end

  defp get_collection_info(nil) do
    # Try to find first active dataset
    case Repo.one(from d in Dataset, where: d.is_active == true, limit: 1) do
      nil -> {nil, []}
      dataset -> get_dataset_config(dataset)
    end
  end

  defp get_collection_info(collection_name) do
    # Find dataset by collection name
    case Repo.one(from d in Dataset, where: d.collection_name == ^collection_name) do
      nil -> {collection_name, []}  # Use collection_name directly, default embedding opts
      dataset -> get_dataset_config(dataset)
    end
  end

  defp get_dataset_config(dataset) do
    settings = dataset.settings || %{}

    # Get embedding config from dataset settings
    provider = settings["embedding_provider"] || "openai"
    api_key = settings["embedding_api_key"]

    # Determine model based on dimension
    model = case dataset.dimension do
      3072 -> "text-embedding-3-large"
      1536 -> "text-embedding-3-small"
      768 -> "text-embedding-004"
      _ -> "text-embedding-3-small"
    end

    opts = [provider: provider, model: model]
    opts = if api_key && api_key != "", do: Keyword.put(opts, :api_key, api_key), else: opts

    {dataset.collection_name, opts}
  end

  defp format_results(results) do
    # Format results for LLM consumption
    formatted =
      results
      |> Enum.with_index(1)
      |> Enum.map(fn {result, idx} ->
        metadata = result["metadata"] || %{}
        question = metadata["question"] || "N/A"
        answer = metadata["answer"] || metadata["content"] || "N/A"
        score = result["score"] || 0

        """
        [#{idx}] ความเกี่ยวข้อง: #{Float.round(score * 100, 1)}%
        คำถาม: #{question}
        คำตอบ: #{answer}
        """
      end)
      |> Enum.join("\n---\n")

    {:ok, "ผลลัพธ์การค้นหา FAQ:\n\n#{formatted}"}
  end
end
