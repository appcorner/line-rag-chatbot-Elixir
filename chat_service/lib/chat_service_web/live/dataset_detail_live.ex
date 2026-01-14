defmodule ChatServiceWeb.DatasetDetailLive do
  use ChatServiceWeb, :live_view

  alias ChatService.Repo
  alias ChatService.Schemas.{Dataset, Document}
  alias ChatService.VectorService.Client, as: VectorClient
  alias ChatService.Services.Embedding.Service, as: EmbeddingService
  import Ecto.Query

  require Logger

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Repo.get(Dataset, id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Dataset not found")
         |> redirect(to: ~p"/datasets")}

      dataset ->
        stats = get_vector_stats(dataset.collection_name)
        per_page = 50
        {documents, total_docs} = load_documents_paginated(dataset.id, 1, per_page)

        # Load saved settings from dataset
        settings = dataset.settings || %{}

        # Auto-detect embedding model based on dimension
        default_model = get_default_model_for_dimension(dataset.dimension)

        {:ok,
         socket
         |> assign(:page_title, dataset.name)
         |> assign(:dataset, dataset)
         |> assign(:stats, stats)
         |> assign(:documents, documents)
         |> assign(:current_page, 1)
         |> assign(:per_page, per_page)
         |> assign(:total_docs, total_docs)
         |> assign(:total_pages, ceil(total_docs / per_page))
         |> assign(:search_query, "")
         |> assign(:search_results, [])
         |> assign(:show_add_modal, false)
         |> assign(:show_search_modal, false)
         |> assign(:show_settings_modal, false)
         |> assign(:show_upload_modal, false)
         |> assign(:show_add_faq_modal, false)
         |> assign(:selected_docs, MapSet.new())
         |> assign(:select_all, false)
         |> assign(:loading, false)
         |> assign(:faq_form, to_form(%{"question" => "", "answer" => ""}))
         |> assign(:embedding_provider, settings["embedding_provider"] || "openai")
         |> assign(:embedding_model, settings["embedding_model"] || default_model)
         |> assign(:embedding_api_key, settings["embedding_api_key"] || "")
         |> assign(:add_form, to_form(%{"content" => "", "doc_id" => "", "metadata" => ""}))
         |> assign(:csv_data, [])
         |> assign(:csv_preview, [])
         |> assign(:upload_progress, 0)
         |> assign(:uploading, false)
         |> allow_upload(:csv_file, accept: ~w(.csv), max_entries: 1, max_file_size: 10_000_000)}
    end
  end

  defp get_vector_stats(collection_name) do
    case VectorClient.get_stats(collection_name) do
      {:ok, stats} -> stats
      _ -> %{}
    end
  end

  defp load_documents_paginated(dataset_id, page, per_page) do
    offset = (page - 1) * per_page

    total = Document
    |> where([d], d.dataset_id == ^dataset_id)
    |> Repo.aggregate(:count)

    documents = Document
    |> where([d], d.dataset_id == ^dataset_id)
    |> order_by([d], desc: d.inserted_at)
    |> limit(^per_page)
    |> offset(^offset)
    |> Repo.all()

    {documents, total}
  end

  # Helper for simple reload (returns just documents, uses current page)
  defp load_documents(dataset_id, socket) do
    page = socket.assigns[:current_page] || 1
    per_page = socket.assigns[:per_page] || 50
    {documents, _} = load_documents_paginated(dataset_id, page, per_page)
    documents
  end

  defp get_default_model_for_dimension(dimension) do
    case dimension do
      3072 -> "text-embedding-3-large"
      1536 -> "text-embedding-3-small"
      768 -> "text-embedding-004"  # Google
      _ -> "text-embedding-3-small"
    end
  end

  defp pagination_range(_current, total) when total <= 7 do
    Enum.to_list(1..total)
  end

  defp pagination_range(current, total) do
    cond do
      current <= 3 ->
        Enum.to_list(1..5) ++ [:ellipsis, total]

      current >= total - 2 ->
        [1, :ellipsis] ++ Enum.to_list((total - 4)..total)

      true ->
        [1, :ellipsis] ++ Enum.to_list((current - 1)..(current + 1)) ++ [:ellipsis, total]
    end
  end

  @impl true
  def handle_event("show_add_modal", _, socket) do
    {:noreply, assign(socket, :show_add_modal, true)}
  end

  def handle_event("show_search_modal", _, socket) do
    {:noreply, assign(socket, :show_search_modal, true)}
  end

  def handle_event("show_settings_modal", _, socket) do
    {:noreply, assign(socket, :show_settings_modal, true)}
  end

  def handle_event("show_upload_modal", _, socket) do
    {:noreply,
     socket
     |> assign(:show_upload_modal, true)
     |> assign(:csv_data, [])
     |> assign(:csv_preview, [])}
  end

  def handle_event("close_modal", _, socket) do
    {:noreply,
     socket
     |> assign(:show_add_modal, false)
     |> assign(:show_search_modal, false)
     |> assign(:show_settings_modal, false)
     |> assign(:show_upload_modal, false)
     |> assign(:show_add_faq_modal, false)
     |> assign(:csv_data, [])
     |> assign(:csv_preview, [])
     |> assign(:faq_form, to_form(%{"question" => "", "answer" => ""}))}
  end

  def handle_event("show_add_faq_modal", _, socket) do
    {:noreply,
     socket
     |> assign(:show_add_faq_modal, true)
     |> assign(:faq_form, to_form(%{"question" => "", "answer" => ""}))}
  end

  def handle_event("toggle_select", %{"id" => doc_id}, socket) do
    selected = socket.assigns.selected_docs
    new_selected = if MapSet.member?(selected, doc_id) do
      MapSet.delete(selected, doc_id)
    else
      MapSet.put(selected, doc_id)
    end

    {:noreply,
     socket
     |> assign(:selected_docs, new_selected)
     |> assign(:select_all, MapSet.size(new_selected) == length(socket.assigns.documents))}
  end

  def handle_event("toggle_select_all", _, socket) do
    new_select_all = !socket.assigns.select_all
    new_selected = if new_select_all do
      socket.assigns.documents
      |> Enum.map(& &1.id)
      |> MapSet.new()
    else
      MapSet.new()
    end

    {:noreply,
     socket
     |> assign(:selected_docs, new_selected)
     |> assign(:select_all, new_select_all)}
  end

  def handle_event("delete_selected", _, socket) do
    selected = socket.assigns.selected_docs
    dataset = socket.assigns.dataset

    if MapSet.size(selected) == 0 do
      {:noreply, put_flash(socket, :error, "No documents selected")}
    else
      # Delete all selected documents
      Enum.each(selected, fn doc_id ->
        case Repo.get(Document, doc_id) do
          nil -> :ok
          doc ->
            # Delete from vector service
            if doc.vector_id do
              VectorClient.delete_vector(dataset.collection_name, doc.vector_id)
            end
            # Delete from database
            Repo.delete(doc)
        end
      end)

      # Refresh data
      stats = get_vector_stats(dataset.collection_name)
      {documents, total_docs} = load_documents_paginated(dataset.id, 1, socket.assigns.per_page)

      {:noreply,
       socket
       |> assign(:stats, stats)
       |> assign(:documents, documents)
       |> assign(:total_docs, total_docs)
       |> assign(:total_pages, ceil(total_docs / socket.assigns.per_page))
       |> assign(:current_page, 1)
       |> assign(:selected_docs, MapSet.new())
       |> assign(:select_all, false)
       |> put_flash(:info, "Deleted #{MapSet.size(selected)} documents")}
    end
  end

  def handle_event("validate_faq", params, socket) do
    {:noreply, assign(socket, :faq_form, to_form(params))}
  end

  def handle_event("save_faq", %{"question" => question, "answer" => answer}, socket) do
    Logger.info("[DatasetDetail] save_faq called: q=#{String.slice(question, 0, 30)}, a=#{String.slice(answer, 0, 30)}")

    if String.trim(question) == "" or String.trim(answer) == "" do
      {:noreply, put_flash(socket, :error, "Question and Answer are required")}
    else
      provider = socket.assigns.embedding_provider
      api_key = socket.assigns.embedding_api_key
      model = socket.assigns.embedding_model

      Logger.info("[DatasetDetail] Embedding settings: provider=#{provider}, model=#{model}, key_len=#{String.length(api_key || "")}")

      if api_key == "" or is_nil(api_key) do
        {:noreply, put_flash(socket, :error, "Please configure Embedding API key in Settings first")}
      else
        # Start embedding process
        socket = socket
        |> assign(:loading, true)
        |> assign(:show_add_faq_modal, false)

        # Embed the question
        content = "#{question}\n#{answer}"
        send(self(), {:embed_faq, question, answer, content, provider, model, api_key})

        {:noreply, socket}
      end
    end
  end

  def handle_event("change_page", %{"page" => page_str}, socket) do
    page = String.to_integer(page_str)
    dataset_id = socket.assigns.dataset.id
    per_page = socket.assigns.per_page

    {documents, _total} = load_documents_paginated(dataset_id, page, per_page)

    {:noreply,
     socket
     |> assign(:documents, documents)
     |> assign(:current_page, page)}
  end

  def handle_event("save_settings", %{"embedding_provider" => provider, "embedding_api_key" => api_key}, socket) do
    dataset = socket.assigns.dataset
    settings = Map.merge(dataset.settings || %{}, %{
      "embedding_provider" => provider,
      "embedding_api_key" => api_key
    })

    case Repo.update(Dataset.changeset(dataset, %{settings: settings})) do
      {:ok, updated_dataset} ->
        {:noreply,
         socket
         |> assign(:dataset, updated_dataset)
         |> assign(:embedding_provider, provider)
         |> assign(:embedding_api_key, api_key)
         |> assign(:show_settings_modal, false)
         |> put_flash(:info, "Settings saved")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to save settings")}
    end
  end

  def handle_event("add_document", %{"question" => question, "answer" => answer, "doc_id" => doc_id}, socket) do
    if question == "" or answer == "" do
      {:noreply, put_flash(socket, :error, "Question and Answer are required")}
    else
      socket = assign(socket, :loading, true)
      doc_id = if doc_id == "", do: Ecto.UUID.generate(), else: doc_id

      # Combine question + answer for embedding
      content = "Q: #{question}\nA: #{answer}"

      # Store question and answer in metadata
      metadata = %{
        "question" => question,
        "answer" => answer,
        "type" => "faq"
      }

      # Get embedding settings from dataset
      provider = socket.assigns.embedding_provider
      model = socket.assigns.embedding_model
      api_key = get_embedding_api_key(socket)

      send(self(), {:embed_and_insert, content, doc_id, metadata, provider, model, api_key})

      {:noreply, socket}
    end
  end

  def handle_event("search", %{"query" => query}, socket) do
    if query == "" do
      {:noreply, assign(socket, :search_results, [])}
    else
      socket = assign(socket, :loading, true)
      provider = socket.assigns.embedding_provider
      model = socket.assigns.embedding_model
      api_key = get_embedding_api_key(socket)
      send(self(), {:do_search, query, provider, model, api_key})
      {:noreply, socket}
    end
  end

  def handle_event("update_search_query", %{"value" => value}, socket) do
    {:noreply, assign(socket, :search_query, value)}
  end

  def handle_event("refresh_stats", _, socket) do
    stats = get_vector_stats(socket.assigns.dataset.collection_name)
    {:noreply, assign(socket, :stats, stats)}
  end

  def handle_event("delete_document", %{"id" => doc_id, "vector_id" => vector_id}, socket) do
    dataset = socket.assigns.dataset

    # Delete from vector_service
    VectorClient.delete_vector(dataset.collection_name, vector_id)

    # Delete from PostgreSQL
    case Repo.get(Document, doc_id) do
      nil -> :ok
      doc -> Repo.delete(doc)
    end

    # Refresh data
    stats = get_vector_stats(dataset.collection_name)
    documents = load_documents(dataset.id, socket)

    {:noreply,
     socket
     |> assign(:stats, stats)
     |> assign(:documents, documents)
     |> put_flash(:info, "Document deleted")}
  end

  def handle_event("validate_csv", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("parse_csv", _params, socket) do
    case uploaded_entries(socket, :csv_file) do
      {[entry], []} ->
        csv_data =
          consume_uploaded_entry(socket, entry, fn %{path: path} ->
            content = File.read!(path)
            Logger.info("[DatasetDetail] CSV content length: #{byte_size(content)}")
            rows = parse_csv_content(content)
            Logger.info("[DatasetDetail] Parsed #{length(rows)} rows from CSV")
            {:ok, rows}
          end)

        Logger.info("[DatasetDetail] csv_data after consume: #{inspect(csv_data)}")
        preview = Enum.take(csv_data, 5)

        {:noreply,
         socket
         |> assign(:csv_data, csv_data)
         |> assign(:csv_preview, preview)}

      _ ->
        {:noreply, put_flash(socket, :error, "Please select a CSV file")}
    end
  end

  def handle_event("upload_csv", _params, socket) do
    csv_data = socket.assigns.csv_data
    Logger.info("[DatasetDetail] upload_csv called with #{length(csv_data)} rows")

    if csv_data == [] do
      {:noreply, put_flash(socket, :error, "No data to upload. Please parse CSV first.")}
    else
      socket =
        socket
        |> assign(:uploading, true)
        |> assign(:upload_progress, 0)

      provider = socket.assigns.embedding_provider
      model = socket.assigns.embedding_model
      api_key = get_embedding_api_key(socket)

      Logger.info("[DatasetDetail] Starting BATCH upload with provider=#{provider}, model=#{model}")
      # Use batch embedding for speed
      send(self(), {:process_csv_batch_all, csv_data, provider, model, api_key})

      {:noreply, socket}
    end
  end

  defp parse_csv_content(content) do
    content
    |> String.trim()
    |> String.split(~r/\r?\n/)
    |> Enum.drop(1)  # Skip header row
    |> Enum.map(fn line ->
      case String.split(line, ~r/[,\t]/, parts: 2) do
        [question, answer] ->
          %{
            question: String.trim(question) |> String.trim("\""),
            answer: String.trim(answer) |> String.trim("\"")
          }
        [question] ->
          %{question: String.trim(question) |> String.trim("\""), answer: ""}
        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(fn row -> row.question == "" end)
  end

  @impl true
  def handle_info({:embed_faq, question, answer, content, provider, model, api_key}, socket) do
    dataset = socket.assigns.dataset
    Logger.info("[DatasetDetail] embed_faq started: collection=#{dataset.collection_name}")

    case EmbeddingService.embed(content, provider: provider, model: model, api_key: api_key) do
      {:ok, embedding} ->
        doc_id = Ecto.UUID.generate()

        # Insert into vector service
        metadata = %{"question" => question, "answer" => answer}
        case VectorClient.insert(dataset.collection_name, doc_id, embedding, metadata) do
          {:ok, _} ->
            # Save to database using changeset
            doc_attrs = %{
              dataset_id: dataset.id,
              vector_id: doc_id,
              question: question,
              answer: answer,
              doc_type: "faq",
              status: "indexed",
              metadata: %{}
            }
            doc_result = %Document{}
              |> Document.changeset(doc_attrs)
              |> Repo.insert()

            case doc_result do
              {:ok, _doc} ->
                # Refresh data
                stats = get_vector_stats(dataset.collection_name)
                {documents, total_docs} = load_documents_paginated(dataset.id, 1, socket.assigns.per_page)

                {:noreply,
                 socket
                 |> assign(:stats, stats)
                 |> assign(:documents, documents)
                 |> assign(:total_docs, total_docs)
                 |> assign(:total_pages, ceil(total_docs / socket.assigns.per_page))
                 |> assign(:current_page, 1)
                 |> assign(:loading, false)
                 |> put_flash(:info, "FAQ added successfully")}

              {:error, changeset} ->
                Logger.error("[DatasetDetail] Failed to save FAQ to DB: #{inspect(changeset.errors)}")
                {:noreply,
                 socket
                 |> assign(:loading, false)
                 |> put_flash(:error, "Vector saved but DB insert failed: #{inspect(changeset.errors)}")}
            end

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:loading, false)
             |> put_flash(:error, "Failed to insert vector: #{inspect(reason)}")}
        end

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:loading, false)
         |> put_flash(:error, "Embedding failed: #{inspect(reason)}")}
    end
  end

  def handle_info({:process_csv_batch_all, csv_data, provider, model, api_key}, socket) do
    dataset = socket.assigns.dataset
    total = length(csv_data)
    liveview_pid = self()

    Logger.info("[DatasetDetail] Starting async batch embedding for #{total} texts...")

    # Run batch embedding in background Task to avoid blocking LiveView
    Task.start(fn ->
      # Process in chunks of 20 to avoid API timeouts
      chunk_size = 20
      chunks = Enum.chunk_every(csv_data, chunk_size)
      total_chunks = length(chunks)

      {success, failed} =
        chunks
        |> Enum.with_index(1)
        |> Enum.reduce({0, 0}, fn {chunk, chunk_idx}, {s_acc, f_acc} ->
          # Send progress update
          progress = round(chunk_idx / total_chunks * 90)
          send(liveview_pid, {:upload_progress, progress})

          texts = Enum.map(chunk, fn row ->
            "Q: #{row.question}\nA: #{row.answer}"
          end)

          Logger.info("[DatasetDetail] Processing chunk #{chunk_idx}/#{total_chunks} (#{length(texts)} texts)...")
          Logger.info("[DatasetDetail] Using API key: #{if api_key, do: "#{String.slice(api_key || "", 0..10)}...", else: "nil"}")

          result = EmbeddingService.embed_batch(texts, provider: provider, model: model, api_key: api_key)
          Logger.info("[DatasetDetail] Embedding result: #{inspect(result) |> String.slice(0..200)}")

          case result do
            {:ok, embeddings} ->
              # Debug: check embedding dimensions
              first_dim = embeddings |> List.first() |> length()
              Logger.info("[DatasetDetail] Got embeddings with dimension: #{first_dim}, expected: #{dataset.dimension}")

              # Insert vectors and save to DB
              {chunk_success, chunk_failed} =
                chunk
                |> Enum.zip(embeddings)
                |> Enum.reduce({0, 0}, fn {row, embedding}, {s, f} ->
                  doc_id = Ecto.UUID.generate()
                  metadata = %{"question" => row.question, "answer" => row.answer, "type" => "faq"}

                  case VectorClient.insert(dataset.collection_name, doc_id, embedding, metadata) do
                    {:ok, _} ->
                      # Save to PostgreSQL
                      %Document{}
                      |> Document.changeset(%{
                        dataset_id: dataset.id,
                        vector_id: doc_id,
                        question: row.question,
                        answer: row.answer,
                        doc_type: "faq",
                        status: "indexed"
                      })
                      |> Repo.insert()
                      {s + 1, f}
                    {:error, err} ->
                      Logger.error("[DatasetDetail] Insert failed: #{inspect(err)}")
                      {s, f + 1}
                  end
                end)

              {s_acc + chunk_success, f_acc + chunk_failed}

            {:error, reason} ->
              Logger.error("[DatasetDetail] Chunk #{chunk_idx} embedding failed: #{inspect(reason)}")
              {s_acc, f_acc + length(chunk)}
          end
        end)

      # Send completion message
      send(liveview_pid, {:batch_upload_complete, success, failed})
    end)

    {:noreply, socket}
  end

  def handle_info({:upload_progress, progress}, socket) do
    {:noreply, assign(socket, :upload_progress, progress)}
  end

  def handle_info({:batch_upload_complete, success, failed}, socket) do
    dataset = socket.assigns.dataset
    stats = get_vector_stats(dataset.collection_name)
    documents = load_documents(dataset.id, socket)

    Logger.info("[DatasetDetail] Batch upload complete: #{success} success, #{failed} failed")

    {:noreply,
     socket
     |> assign(:stats, stats)
     |> assign(:documents, documents)
     |> assign(:uploading, false)
     |> assign(:upload_progress, 100)
     |> assign(:show_upload_modal, false)
     |> assign(:csv_data, [])
     |> assign(:csv_preview, [])
     |> put_flash(:info, "Uploaded #{success} FAQ items successfully" <> if(failed > 0, do: " (#{failed} failed)", else: ""))}
  end

  # Keep old handlers for backward compatibility
  def handle_info({:process_csv_batch, [], _provider, _model, _api_key, count}, socket) do
    stats = get_vector_stats(socket.assigns.dataset.collection_name)
    documents = load_documents(socket.assigns.dataset.id, socket)

    {:noreply,
     socket
     |> assign(:stats, stats)
     |> assign(:documents, documents)
     |> assign(:uploading, false)
     |> assign(:upload_progress, 100)
     |> assign(:show_upload_modal, false)
     |> assign(:csv_data, [])
     |> assign(:csv_preview, [])
     |> put_flash(:info, "Uploaded #{count} FAQ items successfully")}
  end

  def handle_info({:process_csv_batch, [row | rest], provider, model, api_key, count}, socket) do
    dataset = socket.assigns.dataset
    total = length(socket.assigns.csv_data)
    progress = round((count + 1) / total * 100)

    content = "Q: #{row.question}\nA: #{row.answer}"
    metadata = %{"question" => row.question, "answer" => row.answer, "type" => "faq"}
    doc_id = Ecto.UUID.generate()

    Logger.info("[DatasetDetail] Processing row #{count + 1}/#{total}: #{String.slice(row.question, 0..30)}...")

    case EmbeddingService.embed(content, provider: provider, model: model, api_key: api_key) do
      {:ok, embedding} ->
        case VectorClient.insert(dataset.collection_name, doc_id, embedding, metadata) do
          {:ok, _} ->
            Logger.info("[DatasetDetail] Inserted row #{count + 1} successfully")
          {:error, insert_err} ->
            Logger.error("[DatasetDetail] Insert error: #{inspect(insert_err)}")
        end
        send(self(), {:process_csv_batch, rest, provider, model, api_key, count + 1})
        {:noreply, assign(socket, :upload_progress, progress)}

      {:error, reason} ->
        Logger.error("[DatasetDetail] Embedding error row #{count + 1}: #{inspect(reason)}")
        # Stop on error and show user the error
        stats = get_vector_stats(dataset.collection_name)
        documents = load_documents(dataset.id, socket)
        {:noreply,
         socket
         |> assign(:stats, stats)
         |> assign(:documents, documents)
         |> assign(:uploading, false)
         |> assign(:upload_progress, 0)
         |> put_flash(:error, "Embedding failed at row #{count + 1}: #{format_error(reason)}. #{count} rows uploaded successfully.")}
    end
  end

  defp format_error(%{reason: reason}), do: to_string(reason)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  @impl true
  def handle_info({:embed_and_insert, content, doc_id, metadata, provider, model, api_key}, socket) do
    dataset = socket.assigns.dataset
    Logger.info("[DatasetDetail] embed_and_insert started: collection=#{dataset.collection_name}, doc_id=#{doc_id}")

    result =
      with {:ok, embedding} <- EmbeddingService.embed(content, provider: provider, model: model, api_key: api_key),
           {:ok, _} <- VectorClient.insert(
             dataset.collection_name,
             doc_id,
             embedding,
             Map.merge(metadata, %{"content" => content})
           ),
           # Save to database
           {:ok, _doc} <- save_document_to_db(dataset.id, doc_id, metadata, content) do
        :ok
      end

    socket =
      case result do
        :ok ->
          stats = get_vector_stats(dataset.collection_name)
          {documents, total_docs} = load_documents_paginated(dataset.id, 1, socket.assigns.per_page)

          socket
          |> assign(:stats, stats)
          |> assign(:documents, documents)
          |> assign(:total_docs, total_docs)
          |> assign(:total_pages, ceil(total_docs / socket.assigns.per_page))
          |> assign(:current_page, 1)
          |> assign(:show_add_modal, false)
          |> assign(:loading, false)
          |> put_flash(:info, "Document added successfully")

        {:error, reason} ->
          Logger.error("[DatasetDetail] Failed to add document: #{inspect(reason)}")

          socket
          |> assign(:loading, false)
          |> put_flash(:error, "Failed to add document: #{inspect(reason)}")
      end

    {:noreply, socket}
  end

  defp save_document_to_db(dataset_id, vector_id, metadata, content) do
    doc_attrs = %{
      dataset_id: dataset_id,
      vector_id: vector_id,
      question: metadata["question"],
      answer: metadata["answer"],
      content: content,
      doc_type: metadata["type"] || "faq",
      status: "indexed",
      metadata: metadata
    }

    %Document{}
    |> Document.changeset(doc_attrs)
    |> Repo.insert()
  end

  def handle_info({:do_search, query, provider, model, api_key}, socket) do
    dataset = socket.assigns.dataset

    result =
      with {:ok, embedding} <- EmbeddingService.embed(query, provider: provider, model: model, api_key: api_key),
           {:ok, %{"results" => results}} <- VectorClient.search(dataset.collection_name, embedding, 10) do
        {:ok, results}
      end

    socket =
      case result do
        {:ok, results} ->
          socket
          |> assign(:search_results, results)
          |> assign(:loading, false)

        {:error, reason} ->
          Logger.error("[DatasetDetail] Search failed: #{inspect(reason)}")

          socket
          |> assign(:search_results, [])
          |> assign(:loading, false)
          |> put_flash(:error, "Search failed: #{inspect(reason)}")
      end

    {:noreply, socket}
  end

  defp get_embedding_api_key(socket) do
    # Use saved API key from dataset settings, fallback to environment
    case socket.assigns.embedding_api_key do
      key when is_binary(key) and key != "" -> key
      _ ->
        provider = socket.assigns.embedding_provider
        case provider do
          "google" ->
            System.get_env("GOOGLE_API_KEY") ||
              Application.get_env(:chat_service, :google_api_key)
          _ ->
            System.get_env("OPENAI_API_KEY") ||
              Application.get_env(:chat_service, :openai_api_key)
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Header -->
      <div class="flex justify-between items-center">
        <div>
          <div class="flex items-center gap-2">
            <.link navigate={~p"/datasets"} class="text-gray-400 hover:text-white">
              <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7"/>
              </svg>
            </.link>
            <h1 class="text-2xl font-bold"><%= @dataset.name %></h1>
          </div>
          <p class="text-gray-400 mt-1"><%= @dataset.description || "No description" %></p>
        </div>
        <div class="flex gap-2">
          <button
            phx-click="show_settings_modal"
            class="px-4 py-2 bg-gray-600 text-white rounded-lg hover:bg-gray-500 transition"
          >
            <svg class="w-4 h-4 inline mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"/>
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"/>
            </svg>
            Settings
          </button>
          <button
            phx-click="show_search_modal"
            class="px-4 py-2 bg-blue-500 text-white rounded-lg hover:bg-blue-600 transition"
          >
            <svg class="w-4 h-4 inline mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"/>
            </svg>
            Search
          </button>
          <button
            phx-click="show_upload_modal"
            class="px-4 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700 transition"
          >
            <svg class="w-4 h-4 inline mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-8l-4-4m0 0L8 8m4-4v12"/>
            </svg>
            Upload CSV
          </button>
          <button
            phx-click="show_add_modal"
            class="px-4 py-2 bg-orange-500 text-white rounded-lg hover:bg-orange-600 transition"
          >
            + Add FAQ
          </button>
        </div>
      </div>

      <!-- Stats -->
      <div class="grid grid-cols-1 md:grid-cols-4 gap-4">
        <div class="bg-gray-800 rounded-xl border border-gray-700 p-4">
          <p class="text-gray-400 text-sm">Total Vectors</p>
          <p class="text-3xl font-bold"><%= @stats["total_vectors"] || 0 %></p>
        </div>
        <div class="bg-gray-800 rounded-xl border border-gray-700 p-4">
          <p class="text-gray-400 text-sm">Dimension</p>
          <p class="text-3xl font-bold"><%= @dataset.dimension %></p>
        </div>
        <div class="bg-gray-800 rounded-xl border border-gray-700 p-4">
          <p class="text-gray-400 text-sm">Metric</p>
          <p class="text-3xl font-bold capitalize"><%= @dataset.metric %></p>
        </div>
        <div class="bg-gray-800 rounded-xl border border-gray-700 p-4">
          <p class="text-gray-400 text-sm">Memory Usage</p>
          <p class="text-3xl font-bold"><%= format_bytes(@stats["memory_usage_bytes"] || 0) %></p>
        </div>
      </div>

      <!-- Collection Info -->
      <div class="bg-gray-800 rounded-xl border border-gray-700 p-6">
        <div class="flex justify-between items-center mb-4">
          <h2 class="text-lg font-semibold">Collection Info</h2>
          <button
            phx-click="refresh_stats"
            class="text-sm text-gray-400 hover:text-white transition"
          >
            <svg class="w-4 h-4 inline mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"/>
            </svg>
            Refresh
          </button>
        </div>
        <div class="grid grid-cols-2 md:grid-cols-5 gap-4 text-sm">
          <div>
            <p class="text-gray-500">Collection Name</p>
            <p class="font-mono text-xs"><%= @dataset.collection_name %></p>
          </div>
          <div>
            <p class="text-gray-500">Embedding Model</p>
            <p class="text-orange-400 text-xs"><%= @embedding_model %></p>
          </div>
          <div>
            <p class="text-gray-500">Created</p>
            <p><%= Calendar.strftime(@dataset.inserted_at, "%Y-%m-%d %H:%M") %></p>
          </div>
          <div>
            <p class="text-gray-500">ID</p>
            <p class="font-mono text-xs"><%= @dataset.id %></p>
          </div>
          <div>
            <p class="text-gray-500">Status</p>
            <p class="text-green-400">Active</p>
          </div>
        </div>
      </div>

      <!-- All Documents Table -->
      <div class="bg-gray-800 rounded-xl border border-gray-700 overflow-hidden">
        <div class="p-4 border-b border-gray-700 flex justify-between items-center">
          <div class="flex items-center gap-4">
            <h2 class="text-lg font-semibold">All Documents</h2>
            <%= if MapSet.size(@selected_docs) > 0 do %>
              <span class="text-sm text-orange-400">
                <%= MapSet.size(@selected_docs) %> selected
              </span>
              <button
                phx-click="delete_selected"
                data-confirm={"Delete #{MapSet.size(@selected_docs)} selected documents?"}
                class="px-3 py-1 bg-red-500/20 text-red-400 rounded-lg hover:bg-red-500/30 transition text-sm"
              >
                <svg class="w-4 h-4 inline mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"/>
                </svg>
                Delete Selected
              </button>
            <% end %>
          </div>
          <div class="flex items-center gap-4">
            <span class="text-sm text-gray-400">
              <%= @total_docs %> total
              <span class="text-gray-500 mx-1">•</span>
              Page <%= @current_page %>/<%= @total_pages %>
            </span>
            <button
              phx-click="show_add_faq_modal"
              class="px-3 py-1 bg-green-500/20 text-green-400 rounded-lg hover:bg-green-500/30 transition text-sm"
            >
              + Add FAQ
            </button>
          </div>
        </div>
        <%= if @documents == [] do %>
          <div class="p-8 text-center text-gray-500">
            <svg class="w-12 h-12 mx-auto mb-3 opacity-50" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"/>
            </svg>
            <p>No documents yet</p>
            <p class="text-xs mt-1">Add FAQ or upload CSV to get started</p>
          </div>
        <% else %>
          <div class="overflow-x-auto max-h-96 overflow-y-auto">
            <table class="w-full">
              <thead class="bg-gray-900/50 sticky top-0">
                <tr>
                  <th class="px-4 py-3 text-center w-10">
                    <input
                      type="checkbox"
                      checked={@select_all}
                      phx-click="toggle_select_all"
                      class="w-4 h-4 rounded bg-gray-700 border-gray-600 accent-orange-500 cursor-pointer"
                    />
                  </th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase tracking-wider w-12">#</th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase tracking-wider">Question</th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase tracking-wider">Answer</th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase tracking-wider w-20">Status</th>
                  <th class="px-4 py-3 text-center text-xs font-medium text-gray-400 uppercase tracking-wider w-16"></th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-700">
                <% start_idx = (@current_page - 1) * @per_page %>
                <%= for {doc, idx} <- Enum.with_index(@documents, start_idx + 1) do %>
                  <tr class={"#{if MapSet.member?(@selected_docs, doc.id), do: "bg-orange-500/10", else: if(rem(idx, 2) == 0, do: "bg-gray-800", else: "bg-gray-800/50")} hover:bg-gray-700/50 transition"}>
                    <td class="px-4 py-3 text-center">
                      <input
                        type="checkbox"
                        checked={MapSet.member?(@selected_docs, doc.id)}
                        phx-click="toggle_select"
                        phx-value-id={doc.id}
                        class="w-4 h-4 rounded bg-gray-700 border-gray-600 accent-orange-500 cursor-pointer"
                      />
                    </td>
                    <td class="px-4 py-3 text-gray-500 text-sm"><%= idx %></td>
                    <td class="px-4 py-3">
                      <p class="text-sm text-white"><%= doc.question || doc.content || "-" %></p>
                    </td>
                    <td class="px-4 py-3">
                      <p class="text-sm text-gray-300 line-clamp-2"><%= doc.answer || "-" %></p>
                    </td>
                    <td class="px-4 py-3">
                      <span class={"text-xs px-2 py-1 rounded #{if doc.status == "indexed", do: "bg-green-500/20 text-green-400", else: "bg-yellow-500/20 text-yellow-400"}"}><%= doc.status || "indexed" %></span>
                    </td>
                    <td class="px-4 py-3 text-center">
                      <button
                        phx-click="delete_document"
                        phx-value-id={doc.id}
                        phx-value-vector_id={doc.vector_id}
                        data-confirm="Delete this document?"
                        class="text-red-400 hover:text-red-300 transition"
                      >
                        <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"/>
                        </svg>
                      </button>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>

          <!-- Pagination Controls -->
          <%= if @total_pages > 1 do %>
            <div class="p-4 border-t border-gray-700 flex justify-between items-center">
              <div class="text-sm text-gray-400">
                Showing <%= (@current_page - 1) * @per_page + 1 %>-<%= min(@current_page * @per_page, @total_docs) %> of <%= @total_docs %>
              </div>
              <div class="flex items-center gap-2">
                <button
                  phx-click="change_page"
                  phx-value-page={@current_page - 1}
                  disabled={@current_page == 1}
                  class={"px-3 py-1 rounded text-sm transition #{if @current_page == 1, do: "bg-gray-700 text-gray-500 cursor-not-allowed", else: "bg-gray-700 text-white hover:bg-gray-600"}"}
                >
                  ← Prev
                </button>

                <%= for page <- pagination_range(@current_page, @total_pages) do %>
                  <%= if page == :ellipsis do %>
                    <span class="text-gray-500 px-2">...</span>
                  <% else %>
                    <button
                      phx-click="change_page"
                      phx-value-page={page}
                      class={"px-3 py-1 rounded text-sm transition #{if page == @current_page, do: "bg-orange-500 text-white", else: "bg-gray-700 text-white hover:bg-gray-600"}"}
                    >
                      <%= page %>
                    </button>
                  <% end %>
                <% end %>

                <button
                  phx-click="change_page"
                  phx-value-page={@current_page + 1}
                  disabled={@current_page == @total_pages}
                  class={"px-3 py-1 rounded text-sm transition #{if @current_page == @total_pages, do: "bg-gray-700 text-gray-500 cursor-not-allowed", else: "bg-gray-700 text-white hover:bg-gray-600"}"}
                >
                  Next →
                </button>
              </div>
            </div>
          <% end %>
        <% end %>
      </div>

      <!-- Search Results - Table Format -->
      <%= if @search_results != [] do %>
        <div class="bg-gray-800 rounded-xl border border-gray-700 overflow-hidden">
          <div class="p-4 border-b border-gray-700 flex justify-between items-center">
            <h2 class="text-lg font-semibold">Search Results</h2>
            <span class="text-sm text-gray-400"><%= length(@search_results) %> results</span>
          </div>
          <div class="overflow-x-auto">
            <table class="w-full">
              <thead class="bg-gray-900/50">
                <tr>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase tracking-wider w-16">Score</th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase tracking-wider">Question</th>
                  <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase tracking-wider">Answer</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-700">
                <%= for {result, idx} <- Enum.with_index(@search_results) do %>
                  <tr class={"#{if rem(idx, 2) == 0, do: "bg-gray-800", else: "bg-gray-800/50"} hover:bg-gray-700/50 transition"}>
                    <td class="px-4 py-3 whitespace-nowrap">
                      <span class="text-sm font-medium px-2 py-1 bg-orange-500/20 text-orange-400 rounded">
                        <%= Float.round(result["score"] * 100, 1) %>%
                      </span>
                    </td>
                    <td class="px-4 py-3">
                      <p class="text-sm text-white"><%= result["metadata"]["question"] || result["metadata"]["content"] || "-" %></p>
                    </td>
                    <td class="px-4 py-3">
                      <p class="text-sm text-gray-300"><%= result["metadata"]["answer"] || "-" %></p>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      <% end %>

      <!-- Add FAQ Modal -->
      <%= if @show_add_modal do %>
        <div class="fixed inset-0 bg-black/60 flex items-center justify-center z-50 p-4">
          <div class="bg-gray-800 rounded-xl border border-gray-700 w-full max-w-lg shadow-2xl" phx-click-away="close_modal">
            <!-- Modal Header -->
            <div class="flex justify-between items-center p-5 border-b border-gray-700">
              <div>
                <h2 class="text-xl font-bold">Add FAQ</h2>
                <p class="text-sm text-gray-400 mt-1">Add question and answer pair</p>
              </div>
              <button phx-click="close_modal" class="text-gray-400 hover:text-white transition">
                <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/>
                </svg>
              </button>
            </div>

            <!-- Modal Body -->
            <.form for={@add_form} phx-submit="add_document" class="p-5 space-y-4">
              <div>
                <label class="block text-sm font-medium mb-1.5">
                  <span class="text-blue-400">Q:</span> Question <span class="text-red-400">*</span>
                </label>
                <input
                  type="text"
                  name="question"
                  required
                  class="w-full px-3 py-2.5 bg-gray-700 border border-gray-600 rounded-lg focus:ring-2 focus:ring-orange-500 transition"
                  placeholder="e.g. วิธีการชำระเงิน?"
                />
              </div>
              <div>
                <label class="block text-sm font-medium mb-1.5">
                  <span class="text-green-400">A:</span> Answer <span class="text-red-400">*</span>
                </label>
                <textarea
                  name="answer"
                  rows="4"
                  required
                  class="w-full px-3 py-2.5 bg-gray-700 border border-gray-600 rounded-lg focus:ring-2 focus:ring-orange-500 transition resize-none"
                  placeholder="e.g. รองรับบัตรเครดิต โอนผ่านธนาคาร และพร้อมเพย์"
                ></textarea>
              </div>
              <div>
                <label class="block text-sm font-medium mb-1.5 text-gray-400">Document ID (optional)</label>
                <input
                  type="text"
                  name="doc_id"
                  class="w-full px-3 py-2.5 bg-gray-700 border border-gray-600 rounded-lg text-sm"
                  placeholder="Auto-generated if empty"
                />
              </div>

              <!-- Preview -->
              <div class="bg-gray-700/50 rounded-lg p-4 text-sm">
                <p class="text-gray-400 text-xs uppercase tracking-wide mb-2">Preview (for embedding)</p>
                <p class="text-gray-300">Q: <span class="text-blue-300">[question]</span></p>
                <p class="text-gray-300">A: <span class="text-green-300">[answer]</span></p>
              </div>

              <!-- Modal Footer -->
              <div class="flex gap-3 pt-4 border-t border-gray-700">
                <button
                  type="button"
                  phx-click="close_modal"
                  class="flex-1 px-4 py-2.5 bg-gray-700 text-white rounded-lg hover:bg-gray-600 transition"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  disabled={@loading}
                  class="flex-1 px-4 py-2.5 bg-orange-500 text-white rounded-lg hover:bg-orange-600 transition disabled:opacity-50 font-medium"
                >
                  <%= if @loading do %>
                    <svg class="w-5 h-5 inline animate-spin mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"/>
                    </svg>
                    Embedding...
                  <% else %>
                    Add FAQ
                  <% end %>
                </button>
              </div>
            </.form>
          </div>
        </div>
      <% end %>

      <!-- Search Modal -->
      <%= if @show_search_modal do %>
        <div class="fixed inset-0 bg-black/50 flex items-center justify-center z-50 p-4">
          <div class="bg-gray-800 rounded-xl border border-gray-700 p-6 w-full max-w-lg" phx-click-away="close_modal">
            <h2 class="text-xl font-bold mb-4">Search Documents</h2>
            <.form for={%{}} phx-submit="search" class="space-y-4">
              <div>
                <label class="block text-sm font-medium mb-1">Search Query</label>
                <input
                  type="text"
                  name="query"
                  value={@search_query}
                  phx-keyup="update_search_query"
                  class="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg focus:ring-2 focus:ring-blue-500"
                  placeholder="Enter search query..."
                  autofocus
                />
                <p class="text-xs text-gray-500 mt-1">Semantic search using embeddings</p>
              </div>
              <div class="flex gap-3 pt-4">
                <button
                  type="button"
                  phx-click="close_modal"
                  class="flex-1 px-4 py-2 bg-gray-700 text-white rounded-lg hover:bg-gray-600 transition"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  disabled={@loading || @search_query == ""}
                  class="flex-1 px-4 py-2 bg-blue-500 text-white rounded-lg hover:bg-blue-600 transition disabled:opacity-50"
                >
                  <%= if @loading do %>
                    <svg class="w-5 h-5 inline animate-spin mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"/>
                    </svg>
                    Searching...
                  <% else %>
                    Search
                  <% end %>
                </button>
              </div>
            </.form>
          </div>
        </div>
      <% end %>

      <!-- Settings Modal -->
      <%= if @show_settings_modal do %>
        <div class="fixed inset-0 bg-black/50 flex items-center justify-center z-50 p-4">
          <div class="bg-gray-800 rounded-xl border border-gray-700 p-6 w-full max-w-lg" phx-click-away="close_modal">
            <h2 class="text-xl font-bold mb-4">Embedding Settings</h2>
            <.form for={%{}} phx-submit="save_settings" class="space-y-4">
              <div>
                <label class="block text-sm font-medium mb-1">Embedding Provider</label>
                <select
                  name="embedding_provider"
                  class="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg"
                >
                  <option value="openai" selected={@embedding_provider == "openai"}>OpenAI</option>
                  <option value="google" selected={@embedding_provider == "google"}>Google</option>
                </select>
                <p class="text-xs text-gray-500 mt-1">
                  OpenAI: text-embedding-3-small (1536 dim) | Google: text-embedding-004 (768 dim)
                </p>
              </div>
              <div>
                <label class="block text-sm font-medium mb-1">API Key</label>
                <input
                  type="password"
                  name="embedding_api_key"
                  value={@embedding_api_key}
                  class="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg"
                  placeholder="Leave empty to use environment variable"
                />
                <p class="text-xs text-gray-500 mt-1">
                  Optional. Falls back to OPENAI_API_KEY or GOOGLE_API_KEY env var.
                </p>
              </div>
              <div class="bg-gray-700/50 rounded-lg p-3 text-sm">
                <p class="text-gray-400 mb-1">Current Status:</p>
                <p>
                  Provider: <span class="text-orange-400"><%= @embedding_provider %></span>
                  | API Key: <span class="text-green-400"><%= if @embedding_api_key != "", do: "Custom", else: "Environment" %></span>
                </p>
              </div>
              <div class="flex gap-3 pt-4">
                <button
                  type="button"
                  phx-click="close_modal"
                  class="flex-1 px-4 py-2 bg-gray-700 text-white rounded-lg hover:bg-gray-600 transition"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  class="flex-1 px-4 py-2 bg-orange-500 text-white rounded-lg hover:bg-orange-600 transition"
                >
                  Save Settings
                </button>
              </div>
            </.form>
          </div>
        </div>
      <% end %>

      <!-- Add FAQ Modal (Quick Add) -->
      <%= if @show_add_faq_modal do %>
        <div class="fixed inset-0 bg-black/60 flex items-center justify-center z-50 p-4">
          <div class="bg-gray-800 rounded-xl border border-gray-700 w-full max-w-lg shadow-2xl" phx-click-away="close_modal">
            <!-- Modal Header -->
            <div class="flex justify-between items-center p-5 border-b border-gray-700">
              <div>
                <h2 class="text-xl font-bold">Add FAQ</h2>
                <p class="text-sm text-gray-400 mt-1">Add a new question and answer pair</p>
              </div>
              <button phx-click="close_modal" class="text-gray-400 hover:text-white transition">
                <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/>
                </svg>
              </button>
            </div>

            <!-- Modal Body -->
            <.form for={@faq_form} phx-submit="save_faq" phx-change="validate_faq" class="p-5 space-y-4">
              <div>
                <label class="block text-sm font-medium mb-1.5">
                  <span class="text-blue-400">Q:</span> Question <span class="text-red-400">*</span>
                </label>
                <input
                  type="text"
                  name="question"
                  value={@faq_form[:question].value}
                  required
                  class="w-full px-3 py-2.5 bg-gray-700 border border-gray-600 rounded-lg focus:ring-2 focus:ring-orange-500 transition"
                  placeholder="e.g. วิธีการชำระเงิน?"
                />
              </div>
              <div>
                <label class="block text-sm font-medium mb-1.5">
                  <span class="text-green-400">A:</span> Answer <span class="text-red-400">*</span>
                </label>
                <textarea
                  name="answer"
                  rows="4"
                  required
                  class="w-full px-3 py-2.5 bg-gray-700 border border-gray-600 rounded-lg focus:ring-2 focus:ring-orange-500 transition resize-none"
                  placeholder="e.g. รองรับบัตรเครดิต โอนผ่านธนาคาร และพร้อมเพย์"
                ><%= @faq_form[:answer].value %></textarea>
              </div>

              <!-- Embedding Info -->
              <div class="bg-gray-700/50 rounded-lg p-3 text-sm">
                <p class="text-gray-400 text-xs uppercase tracking-wide mb-1">Embedding Settings</p>
                <p class="text-gray-300">
                  Provider: <span class="text-orange-400"><%= @embedding_provider %></span>
                  | Model: <span class="text-blue-400"><%= @embedding_model %></span>
                </p>
              </div>

              <!-- Modal Footer -->
              <div class="flex gap-3 pt-4 border-t border-gray-700">
                <button
                  type="button"
                  phx-click="close_modal"
                  class="flex-1 px-4 py-2.5 bg-gray-700 text-white rounded-lg hover:bg-gray-600 transition"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  disabled={@loading}
                  class="flex-1 px-4 py-2.5 bg-green-600 text-white rounded-lg hover:bg-green-700 transition disabled:opacity-50 font-medium"
                >
                  <%= if @loading do %>
                    <svg class="w-5 h-5 inline animate-spin mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"/>
                    </svg>
                    Embedding...
                  <% else %>
                    Add FAQ
                  <% end %>
                </button>
              </div>
            </.form>
          </div>
        </div>
      <% end %>

      <!-- Upload CSV Modal -->
      <%= if @show_upload_modal do %>
        <div class="fixed inset-0 bg-black/60 flex items-center justify-center z-50 p-4">
          <div class="bg-gray-800 rounded-xl border border-gray-700 w-full max-w-2xl shadow-2xl" phx-click-away="close_modal">
            <!-- Modal Header -->
            <div class="flex justify-between items-center p-5 border-b border-gray-700">
              <div>
                <h2 class="text-xl font-bold">Upload CSV</h2>
                <p class="text-sm text-gray-400 mt-1">Import FAQ from CSV file</p>
              </div>
              <button phx-click="close_modal" class="text-gray-400 hover:text-white transition">
                <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/>
                </svg>
              </button>
            </div>

            <!-- Modal Body -->
            <div class="p-5 space-y-4">
              <!-- CSV Format Info -->
              <div class="bg-gray-700/50 rounded-lg p-4">
                <p class="text-sm font-medium text-gray-300 mb-2">CSV Format:</p>
                <code class="text-xs text-green-400 block bg-gray-900 rounded p-2 font-mono">
                  Question,Answer<br/>
                  วิธีการชำระเงิน?,รองรับบัตรเครดิต โอนผ่านธนาคาร และพร้อมเพย์<br/>
                  ระยะเวลาจัดส่งสินค้า?,จัดส่งภายใน 3-5 วันทำการ
                </code>
              </div>

              <!-- File Upload -->
              <.form for={%{}} phx-change="validate_csv" phx-submit="parse_csv" class="space-y-4">
                <div class="border-2 border-dashed border-gray-600 rounded-lg p-6 text-center hover:border-green-500 transition">
                  <.live_file_input upload={@uploads.csv_file} class="hidden" />
                  <label for={@uploads.csv_file.ref} class="cursor-pointer">
                    <svg class="w-12 h-12 mx-auto text-gray-500 mb-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M7 16a4 4 0 01-.88-7.903A5 5 0 1115.9 6L16 6a5 5 0 011 9.9M15 13l-3-3m0 0l-3 3m3-3v12"/>
                    </svg>
                    <p class="text-gray-400">Click to select CSV file</p>
                    <p class="text-xs text-gray-500 mt-1">Max 10MB</p>
                  </label>
                  <%= for entry <- @uploads.csv_file.entries do %>
                    <div class="mt-3 flex items-center justify-center gap-2 text-green-400">
                      <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/>
                      </svg>
                      <span class="text-sm"><%= entry.client_name %></span>
                    </div>
                  <% end %>
                </div>

                <%= if @uploads.csv_file.entries != [] and @csv_preview == [] do %>
                  <button
                    type="submit"
                    class="w-full px-4 py-2.5 bg-blue-500 text-white rounded-lg hover:bg-blue-600 transition font-medium"
                  >
                    Parse CSV
                  </button>
                <% end %>
              </.form>

              <!-- Preview Table -->
              <%= if @csv_preview != [] do %>
                <div class="border border-gray-700 rounded-lg overflow-hidden">
                  <div class="p-3 bg-gray-700/50 border-b border-gray-700 flex justify-between items-center">
                    <span class="text-sm font-medium">Preview (<%= length(@csv_data) %> rows)</span>
                    <span class="text-xs text-gray-400">Showing first 5 rows</span>
                  </div>
                  <div class="overflow-x-auto">
                    <table class="w-full text-sm">
                      <thead class="bg-gray-900/50">
                        <tr>
                          <th class="px-3 py-2 text-left text-xs font-medium text-gray-400">#</th>
                          <th class="px-3 py-2 text-left text-xs font-medium text-gray-400">Question</th>
                          <th class="px-3 py-2 text-left text-xs font-medium text-gray-400">Answer</th>
                        </tr>
                      </thead>
                      <tbody class="divide-y divide-gray-700">
                        <%= for {row, idx} <- Enum.with_index(@csv_preview, 1) do %>
                          <tr class="hover:bg-gray-700/30">
                            <td class="px-3 py-2 text-gray-500"><%= idx %></td>
                            <td class="px-3 py-2 text-blue-300"><%= row.question %></td>
                            <td class="px-3 py-2 text-gray-300"><%= row.answer %></td>
                          </tr>
                        <% end %>
                      </tbody>
                    </table>
                  </div>
                </div>

                <!-- Progress Bar -->
                <%= if @uploading do %>
                  <div class="space-y-2">
                    <div class="flex justify-between text-sm">
                      <span class="text-gray-400">Uploading...</span>
                      <span class="text-orange-400"><%= @upload_progress %>%</span>
                    </div>
                    <div class="w-full bg-gray-700 rounded-full h-2">
                      <div class="bg-orange-500 h-2 rounded-full transition-all duration-300" style={"width: #{@upload_progress}%"}></div>
                    </div>
                  </div>
                <% end %>
              <% end %>

              <!-- Modal Footer -->
              <div class="flex gap-3 pt-4 border-t border-gray-700">
                <button
                  type="button"
                  phx-click="close_modal"
                  class="flex-1 px-4 py-2.5 bg-gray-700 text-white rounded-lg hover:bg-gray-600 transition"
                  disabled={@uploading}
                >
                  Cancel
                </button>
                <button
                  type="button"
                  phx-click="upload_csv"
                  disabled={@csv_data == [] or @uploading}
                  class="flex-1 px-4 py-2.5 bg-green-600 text-white rounded-lg hover:bg-green-700 transition disabled:opacity-50 font-medium"
                >
                  <%= if @uploading do %>
                    <svg class="w-5 h-5 inline animate-spin mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"/>
                    </svg>
                    Uploading...
                  <% else %>
                    Upload <%= length(@csv_data) %> FAQs
                  <% end %>
                </button>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes) when bytes < 1024 * 1024 * 1024, do: "#{Float.round(bytes / 1024 / 1024, 1)} MB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1024 / 1024 / 1024, 1)} GB"
end
