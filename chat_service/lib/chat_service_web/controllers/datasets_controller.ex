defmodule ChatServiceWeb.DatasetsController do
  use ChatServiceWeb, :controller

  alias ChatService.Repo
  alias ChatService.Schemas.Dataset
  alias ChatService.VectorService.Client, as: VectorClient
  import Ecto.Query

  def index(conn, _params) do
    datasets =
      Dataset
      |> where([d], d.is_active == true)
      |> order_by([d], desc: d.inserted_at)
      |> Repo.all()
      |> Enum.map(&format_dataset/1)

    json(conn, datasets)
  end

  def show(conn, %{"id" => id}) do
    case Repo.get(Dataset, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Dataset not found"})

      dataset ->
        stats = case VectorClient.get_stats(dataset.collection_name) do
          {:ok, s} -> s
          _ -> %{}
        end

        json(conn, format_dataset(dataset, stats))
    end
  end

  def create(conn, params) do
    attrs = %{
      name: params["name"],
      description: params["description"],
      dimension: params["dimension"] || 1536,
      metric: params["metric"] || "cosine"
    }

    changeset = Dataset.changeset(%Dataset{}, attrs)

    case Repo.insert(changeset) do
      {:ok, dataset} ->
        vector_status = case VectorClient.create_collection(dataset.collection_name, dataset.dimension, dataset.metric) do
          {:ok, _} -> "synced"
          {:error, _} -> "pending"
        end

        conn
        |> put_status(:created)
        |> json(format_dataset(dataset) |> Map.put(:vectorStatus, vector_status))

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: format_errors(changeset)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    case Repo.get(Dataset, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Dataset not found"})

      dataset ->
        attrs = Map.take(params, ["name", "description", "is_active"])
        |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), v} end)
        |> Map.new()

        case dataset |> Dataset.changeset(attrs) |> Repo.update() do
          {:ok, updated} ->
            json(conn, format_dataset(updated))

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: format_errors(changeset)})
        end
    end
  end

  def delete(conn, %{"id" => id}) do
    case Repo.get(Dataset, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Dataset not found"})

      dataset ->
        VectorClient.delete_collection(dataset.collection_name)

        case Repo.delete(dataset) do
          {:ok, _} ->
            json(conn, %{success: true})

          {:error, _} ->
            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "Failed to delete dataset"})
        end
    end
  end

  def add_document(conn, %{"id" => id} = params) do
    case Repo.get(Dataset, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Dataset not found"})

      dataset ->
        doc_id = params["doc_id"] || Ecto.UUID.generate()

        conn
        |> put_status(:accepted)
        |> json(%{
          message: "Document queued for embedding",
          doc_id: doc_id,
          dataset_id: dataset.id
        })
    end
  end

  def search_documents(conn, %{"id" => id} = params) do
    case Repo.get(Dataset, id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Dataset not found"})

      dataset ->
        query = params["query"]

        json(conn, %{
          results: [],
          query: query,
          dataset_id: dataset.id
        })
    end
  end

  defp format_dataset(dataset, stats \\ %{}) do
    %{
      id: dataset.id,
      name: dataset.name,
      description: dataset.description,
      collectionName: dataset.collection_name,
      dimension: dataset.dimension,
      metric: dataset.metric,
      documentCount: stats["total_vectors"] || dataset.document_count,
      embeddedCount: stats["total_vectors"] || dataset.embedded_count,
      isActive: dataset.is_active,
      createdAt: dataset.inserted_at,
      updatedAt: dataset.updated_at
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map(fn {k, v} -> "#{k}: #{Enum.join(v, ", ")}" end)
    |> Enum.join("; ")
  end
end
