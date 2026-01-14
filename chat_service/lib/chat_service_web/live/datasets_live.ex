defmodule ChatServiceWeb.DatasetsLive do
  use ChatServiceWeb, :live_view

  alias ChatService.Repo
  alias ChatService.Schemas.Dataset
  alias ChatService.VectorService.Client, as: VectorClient
  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Datasets")
     |> assign(:datasets, list_datasets())
     |> assign(:show_modal, false)
     |> assign(:form, to_form(%{"name" => "", "description" => "", "dimension" => "1536", "metric" => "cosine"}))}
  end

  @impl true
  def handle_event("show_create_modal", _, socket) do
    {:noreply, assign(socket, :show_modal, true)}
  end

  def handle_event("close_modal", _, socket) do
    {:noreply, assign(socket, :show_modal, false)}
  end

  def handle_event("create_dataset", %{"name" => name, "description" => desc, "dimension" => dim, "metric" => metric}, socket) do
    attrs = %{
      name: name,
      description: desc,
      dimension: String.to_integer(dim),
      metric: metric
    }

    changeset = Dataset.changeset(%Dataset{}, attrs)

    case Repo.insert(changeset) do
      {:ok, dataset} ->
        # Try to create collection in vector_service
        VectorClient.create_collection(dataset.collection_name, dataset.dimension, dataset.metric)

        {:noreply,
         socket
         |> assign(:datasets, list_datasets())
         |> assign(:show_modal, false)
         |> put_flash(:info, "Dataset created successfully")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create dataset")}
    end
  end

  def handle_event("delete_dataset", %{"id" => id}, socket) do
    case Repo.get(Dataset, id) do
      nil ->
        {:noreply, socket}

      dataset ->
        VectorClient.delete_collection(dataset.collection_name)
        Repo.delete(dataset)

        {:noreply,
         socket
         |> assign(:datasets, list_datasets())
         |> put_flash(:info, "Dataset deleted")}
    end
  end

  def handle_event("sync_dataset", %{"id" => id}, socket) do
    case Repo.get(Dataset, id) do
      nil ->
        {:noreply, socket}

      dataset ->
        case VectorClient.create_collection(dataset.collection_name, dataset.dimension, dataset.metric) do
          {:ok, _} ->
            {:noreply, put_flash(socket, :info, "Dataset synced with vector service")}
          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to sync with vector service")}
        end
    end
  end

  defp list_datasets do
    Dataset
    |> where([d], d.is_active == true)
    |> order_by([d], desc: d.inserted_at)
    |> Repo.all()
    |> Enum.map(fn dataset ->
      stats = case VectorClient.get_stats(dataset.collection_name) do
        {:ok, s} -> s
        _ -> %{}
      end
      Map.put(dataset, :vector_count, stats["total_vectors"] || 0)
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Header -->
      <div class="flex justify-between items-center">
        <div>
          <h1 class="text-2xl font-bold">Datasets</h1>
          <p class="text-gray-400 text-sm mt-1">Manage your vector databases for RAG</p>
        </div>
        <button
          phx-click="show_create_modal"
          class="px-4 py-2 bg-orange-500 text-white rounded-lg hover:bg-orange-600 transition flex items-center gap-2"
        >
          <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4"/>
          </svg>
          Create Dataset
        </button>
      </div>

      <!-- Dataset Cards -->
      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        <%= for dataset <- @datasets do %>
          <div class="bg-gray-800 rounded-xl border border-gray-700 overflow-hidden hover:border-orange-500/50 transition group">
            <!-- Card Header -->
            <div class="p-5 border-b border-gray-700">
              <div class="flex justify-between items-start">
                <.link navigate={~p"/datasets/#{dataset.id}"} class="flex-1 min-w-0">
                  <h3 class="font-semibold text-lg truncate group-hover:text-orange-400 transition"><%= dataset.name %></h3>
                  <p class="text-sm text-gray-400 mt-1 line-clamp-2"><%= dataset.description || "No description" %></p>
                </.link>
                <div class="flex gap-1 ml-3 flex-shrink-0">
                  <button
                    phx-click="sync_dataset"
                    phx-value-id={dataset.id}
                    class="p-2 text-gray-400 hover:text-blue-400 hover:bg-gray-700 rounded-lg transition"
                    title="Sync with Vector Service"
                  >
                    <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"/>
                    </svg>
                  </button>
                  <button
                    phx-click="delete_dataset"
                    phx-value-id={dataset.id}
                    class="p-2 text-gray-400 hover:text-red-400 hover:bg-gray-700 rounded-lg transition"
                    data-confirm="Are you sure you want to delete this dataset?"
                  >
                    <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"/>
                    </svg>
                  </button>
                </div>
              </div>
            </div>

            <!-- Card Body - Clickable -->
            <.link navigate={~p"/datasets/#{dataset.id}"} class="block">
              <div class="p-5">
                <div class="grid grid-cols-2 gap-3">
                  <div class="bg-gray-700/50 rounded-lg p-3 text-center">
                    <p class="text-gray-400 text-xs uppercase tracking-wide">Vectors</p>
                    <p class="text-2xl font-bold text-orange-400 mt-1"><%= dataset.vector_count %></p>
                  </div>
                  <div class="bg-gray-700/50 rounded-lg p-3 text-center">
                    <p class="text-gray-400 text-xs uppercase tracking-wide">Dimension</p>
                    <p class="text-2xl font-bold mt-1"><%= dataset.dimension %></p>
                  </div>
                </div>
              </div>

              <!-- Card Footer -->
              <div class="px-5 py-3 bg-gray-900/50 border-t border-gray-700 text-xs text-gray-500 flex justify-between">
                <span class="font-mono truncate flex-1"><%= dataset.collection_name %></span>
                <span class="ml-2 px-2 py-0.5 bg-gray-700 rounded text-gray-400"><%= dataset.metric %></span>
              </div>
            </.link>
          </div>
        <% end %>

        <!-- Empty State -->
        <%= if @datasets == [] do %>
          <div class="col-span-full bg-gray-800 rounded-xl border border-gray-700 border-dashed p-12 text-center">
            <div class="w-16 h-16 mx-auto bg-gray-700 rounded-full flex items-center justify-center mb-4">
              <svg class="w-8 h-8 text-gray-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 7v10c0 2.21 3.582 4 8 4s8-1.79 8-4V7M4 7c0 2.21 3.582 4 8 4s8-1.79 8-4M4 7c0-2.21 3.582-4 8-4s8 1.79 8 4"/>
              </svg>
            </div>
            <h3 class="text-lg font-semibold mb-2">No datasets yet</h3>
            <p class="text-gray-400 mb-6 max-w-sm mx-auto">Create your first dataset to start building your knowledge base for RAG</p>
            <button
              phx-click="show_create_modal"
              class="px-6 py-2.5 bg-orange-500 text-white rounded-lg hover:bg-orange-600 transition inline-flex items-center gap-2"
            >
              <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4"/>
              </svg>
              Create Dataset
            </button>
          </div>
        <% end %>
      </div>

      <!-- Create Modal -->
      <%= if @show_modal do %>
        <div class="fixed inset-0 bg-black/60 flex items-center justify-center z-50 p-4">
          <div class="bg-gray-800 rounded-xl border border-gray-700 w-full max-w-md shadow-2xl" phx-click-away="close_modal">
            <!-- Modal Header -->
            <div class="flex justify-between items-center p-5 border-b border-gray-700">
              <h2 class="text-xl font-bold">Create Dataset</h2>
              <button phx-click="close_modal" class="text-gray-400 hover:text-white transition">
                <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/>
                </svg>
              </button>
            </div>

            <!-- Modal Body -->
            <.form for={@form} phx-submit="create_dataset" class="p-5 space-y-4">
              <div>
                <label class="block text-sm font-medium mb-1.5">Name <span class="text-red-400">*</span></label>
                <input
                  type="text"
                  name="name"
                  required
                  class="w-full px-3 py-2.5 bg-gray-700 border border-gray-600 rounded-lg focus:ring-2 focus:ring-orange-500 focus:border-transparent transition"
                  placeholder="My Dataset"
                />
              </div>
              <div>
                <label class="block text-sm font-medium mb-1.5">Description</label>
                <textarea
                  name="description"
                  rows="3"
                  class="w-full px-3 py-2.5 bg-gray-700 border border-gray-600 rounded-lg focus:ring-2 focus:ring-orange-500 focus:border-transparent transition resize-none"
                  placeholder="Optional description for this dataset..."
                ></textarea>
              </div>
              <div class="grid grid-cols-2 gap-4">
                <div>
                  <label class="block text-sm font-medium mb-1.5">Dimension</label>
                  <select name="dimension" class="w-full px-3 py-2.5 bg-gray-700 border border-gray-600 rounded-lg focus:ring-2 focus:ring-orange-500 transition">
                    <option value="384">384 (MiniLM)</option>
                    <option value="768">768 (Google)</option>
                    <option value="1024">1024 (Large)</option>
                    <option value="1536" selected>1536 (OpenAI)</option>
                    <option value="3072">3072 (OpenAI Large)</option>
                  </select>
                </div>
                <div>
                  <label class="block text-sm font-medium mb-1.5">Metric</label>
                  <select name="metric" class="w-full px-3 py-2.5 bg-gray-700 border border-gray-600 rounded-lg focus:ring-2 focus:ring-orange-500 transition">
                    <option value="cosine" selected>Cosine</option>
                    <option value="euclidean">Euclidean</option>
                    <option value="dot">Dot Product</option>
                  </select>
                </div>
              </div>

              <!-- Modal Footer -->
              <div class="flex gap-3 pt-4 border-t border-gray-700 mt-6">
                <button
                  type="button"
                  phx-click="close_modal"
                  class="flex-1 px-4 py-2.5 bg-gray-700 text-white rounded-lg hover:bg-gray-600 transition"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  class="flex-1 px-4 py-2.5 bg-orange-500 text-white rounded-lg hover:bg-orange-600 transition font-medium"
                >
                  Create Dataset
                </button>
              </div>
            </.form>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
