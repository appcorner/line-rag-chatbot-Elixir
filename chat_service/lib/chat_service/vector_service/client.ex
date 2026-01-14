defmodule ChatService.VectorService.Client do
  @moduledoc """
  HTTP client for communicating with vector_service.
  """

  @default_url "http://localhost:50052"

  def base_url do
    System.get_env("VECTOR_SERVICE_URL", @default_url)
  end

  # Collections (Datasets)

  def list_collections do
    case get("/collections") do
      {:ok, %{"collections" => collections}} -> {:ok, collections}
      {:ok, body} -> {:ok, body}
      error -> error
    end
  end

  def create_collection(name, dimension \\ 1536, metric \\ "cosine") do
    body = %{
      name: name,
      dimension: dimension,
      metric: metric,
      m: 16,
      ef_construction: 200,
      ef_search: 50
    }

    post("/collections", body)
  end

  def delete_collection(name) do
    delete("/collections/#{name}")
  end

  def get_stats(collection) do
    get("/stats/#{collection}")
  end

  def get_count(collection) do
    get("/count/#{collection}")
  end

  # Vectors

  def insert(collection, id, values, metadata \\ %{}) do
    require Logger

    # Round floats to 6 decimal places to reduce JSON size
    # This avoids C++ JSON parser buffer limits while maintaining embedding quality
    rounded_values = Enum.map(values, &Float.round(&1, 6))

    Logger.debug("[VectorClient] insert: collection=#{collection}, id=#{id}, values_len=#{length(rounded_values)}")

    body = %{
      collection: collection,
      vector: %{
        id: id,
        values: rounded_values,
        metadata: metadata
      }
    }

    post("/insert", body)
  end

  def batch_insert(collection, vectors) do
    body = %{
      collection: collection,
      vectors: vectors
    }

    post("/batch_insert", body)
  end

  def search(collection, query, top_k \\ 10) do
    # Round floats to 6 decimal places to reduce JSON size
    rounded_query = Enum.map(query, &Float.round(&1, 6))

    body = %{
      collection: collection,
      query: rounded_query,
      top_k: top_k
    }

    case post("/search", body) do
      {:ok, %{"results" => results, "search_time_ms" => time}} ->
        parsed =
          Enum.map(results, fn r ->
            %{
              id: r["id"],
              score: r["score"],
              metadata: r["metadata"] || %{}
            }
          end)
        {:ok, %{results: parsed, time_ms: time}}

      {:ok, response} ->
        {:error, "Unexpected response: #{inspect(response)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  List all vectors in a collection.
  Returns {:ok, [%{id, metadata, ...}]} or {:error, reason}
  """
  def list_vectors(collection, limit \\ 100) do
    # Try list endpoint
    case get("/list/#{collection}?limit=#{limit}") do
      {:ok, %{"vectors" => vectors}} -> {:ok, vectors}
      {:ok, body} when is_list(body) -> {:ok, body}
      {:error, _} ->
        # Fallback: try browse endpoint
        case get("/browse/#{collection}?limit=#{limit}") do
          {:ok, %{"vectors" => vectors}} -> {:ok, vectors}
          {:ok, body} when is_list(body) -> {:ok, body}
          _ -> {:ok, []}
        end
    end
  end

  def search_with_filter(collection, query, filters, top_k \\ 10) do
    body = %{
      collection: collection,
      query: query,
      top_k: top_k,
      filter: filters
    }

    post("/search_with_filter", body)
  end

  def delete_vector(collection, id) do
    delete("/vectors/#{collection}/#{id}")
  end

  def get_vector(collection, id) do
    get("/vectors/#{collection}/#{id}")
  end

  # Health

  def health do
    get("/health")
  end

  # Private HTTP helpers

  defp get(path) do
    url = base_url() <> path

    case :httpc.request(:get, {to_charlist(url), []}, [{:timeout, 30_000}], []) do
      {:ok, {{_, 200, _}, _, body}} ->
        {:ok, Jason.decode!(to_string(body))}

      {:ok, {{_, status, _}, _, body}} ->
        {:error, %{status: status, body: to_string(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp post(path, body) do
    require Logger
    url = base_url() <> path
    json_body = Jason.encode!(body)
    Logger.debug("[VectorClient] POST #{path}: body_size=#{byte_size(json_body)}, first_100=#{String.slice(json_body, 0..100)}")

    case :httpc.request(
           :post,
           {to_charlist(url), [], ~c"application/json", json_body},
           [{:timeout, 30_000}],
           []
         ) do
      {:ok, {{_, 200, _}, _, resp_body}} ->
        {:ok, Jason.decode!(to_string(resp_body))}

      {:ok, {{_, status, _}, _, resp_body}} ->
        {:error, %{status: status, body: to_string(resp_body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delete(path) do
    url = base_url() <> path

    case :httpc.request(:delete, {to_charlist(url), []}, [{:timeout, 30_000}], []) do
      {:ok, {{_, 200, _}, _, body}} ->
        {:ok, Jason.decode!(to_string(body))}

      {:ok, {{_, status, _}, _, body}} ->
        {:error, %{status: status, body: to_string(body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
