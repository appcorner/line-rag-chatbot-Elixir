defmodule ChatServiceWeb.ChannelsLive do
  use ChatServiceWeb, :live_view

  alias ChatService.Repo
  alias ChatService.Schemas.Channel
  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "LINE OA Channels")
     |> assign(:channels, list_channels())
     |> assign(:datasets, list_datasets())
     |> assign(:show_modal, false)
     |> assign(:available_models, [])
     |> assign(:loading_models, false)
     |> assign(:form, to_form(default_form()))}
  end

  defp default_form do
    %{
      "name" => "",
      "channel_id" => "",
      "access_token" => "",
      "channel_secret" => "",
      "is_active" => true,
      "llm_provider" => "openai",
      "llm_model" => "gpt-4o-mini",
      "llm_api_key" => ""
    }
  end

  defp list_channels do
    Channel
    |> order_by([c], desc: c.inserted_at)
    |> Repo.all()
  end

  defp list_datasets do
    ChatService.Schemas.Dataset
    |> where([d], d.is_active == true)
    |> order_by([d], asc: d.name)
    |> Repo.all()
  end

  @impl true
  def handle_event("show_create_modal", _, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, true)
     |> assign(:form, to_form(default_form()))}
  end

  def handle_event("close_modal", _, socket) do
    {:noreply, assign(socket, :show_modal, false)}
  end

  def handle_event("fetch_models", %{"provider" => provider, "api_key" => api_key}, socket) do
    if api_key != "" do
      # Start async task to fetch models
      socket = assign(socket, :loading_models, true)
      send(self(), {:fetch_models, provider, api_key})
      {:noreply, socket}
    else
      {:noreply, assign(socket, :available_models, [])}
    end
  end

  def handle_event("validate", params, socket) do
    # Get the target field that changed
    target = params["_target"] || []

    # Filter out LiveView internal params
    new_params = Map.drop(params, ["_target", "_csrf_token"])

    # Handle checkboxes - if target is a checkbox field and not in params, it was unchecked
    checkbox_fields = ["is_active"]
    form_params = socket.assigns.form.params

    form_params = Enum.reduce(checkbox_fields, form_params, fn field, acc ->
      if field in target and not Map.has_key?(new_params, field) do
        Map.put(acc, field, false)
      else
        acc
      end
    end)

    # Merge new params
    form_params = Map.merge(form_params, new_params)

    {:noreply, assign(socket, :form, to_form(form_params))}
  end

  def handle_event("copy_webhook", %{"url" => url}, socket) do
    {:noreply,
     socket
     |> push_event("copy_to_clipboard", %{text: url})
     |> put_flash(:info, "Webhook URL copied!")}
  end

  @impl true
  def handle_info({:fetch_models, provider, api_key}, socket) do
    models = fetch_models_from_provider(provider, api_key)
    {:noreply,
     socket
     |> assign(:available_models, models)
     |> assign(:loading_models, false)}
  end

  defp fetch_models_from_provider("openai", api_key) do
    case Req.get("https://api.openai.com/v1/models",
           headers: [{"Authorization", "Bearer #{api_key}"}],
           receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"data" => models}}} ->
        models
        |> Enum.filter(fn m -> String.contains?(m["id"], "gpt") end)
        |> Enum.map(fn m -> %{id: m["id"], name: m["id"]} end)
        |> Enum.sort_by(& &1.name)
      _ ->
        []
    end
  end

  defp fetch_models_from_provider("anthropic", api_key) do
    # Anthropic doesn't have a models API, return known models
    if api_key != "" do
      [
        %{id: "claude-3-5-sonnet-20241022", name: "Claude 3.5 Sonnet"},
        %{id: "claude-3-5-haiku-20241022", name: "Claude 3.5 Haiku"},
        %{id: "claude-3-opus-20240229", name: "Claude 3 Opus"}
      ]
    else
      []
    end
  end

  defp fetch_models_from_provider("google", api_key) do
    case Req.get("https://generativelanguage.googleapis.com/v1/models?key=#{api_key}",
           receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"models" => models}}} ->
        models
        |> Enum.filter(fn m -> String.contains?(m["name"] || "", "gemini") end)
        |> Enum.map(fn m ->
          id = String.replace(m["name"] || "", "models/", "")
          %{id: id, name: m["displayName"] || id}
        end)
      _ ->
        []
    end
  end

  defp fetch_models_from_provider("groq", api_key) do
    case Req.get("https://api.groq.com/openai/v1/models",
           headers: [{"Authorization", "Bearer #{api_key}"}],
           receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"data" => models}}} ->
        models
        |> Enum.map(fn m -> %{id: m["id"], name: m["id"]} end)
        |> Enum.sort_by(& &1.name)
      _ ->
        []
    end
  end

  defp fetch_models_from_provider("ollama", _api_key) do
    # Ollama runs locally, try to fetch from local server
    case Req.get("http://localhost:11434/api/tags", receive_timeout: 5_000) do
      {:ok, %{status: 200, body: %{"models" => models}}} ->
        models
        |> Enum.map(fn m -> %{id: m["name"], name: m["name"]} end)
      _ ->
        [
          %{id: "llama3.2", name: "Llama 3.2"},
          %{id: "llama3.1", name: "Llama 3.1"},
          %{id: "mistral", name: "Mistral"},
          %{id: "qwen2.5", name: "Qwen 2.5"}
        ]
    end
  end

  defp fetch_models_from_provider(_, _), do: []

  def handle_event("save_channel", _params, socket) do
    # Get form params from the socket's form (updated by validate)
    form_params = socket.assigns.form.params

    attrs = %{
      name: form_params["name"] || "",
      channel_id: form_params["channel_id"] || "",
      access_token: form_params["access_token"] || "",
      channel_secret: form_params["channel_secret"] || "",
      is_active: form_params["is_active"] == true || form_params["is_active"] == "true",
      settings: %{
        "ai_enabled" => true,
        "llm_provider" => form_params["llm_provider"] || "openai",
        "llm_model" => form_params["llm_model"] || "gpt-4o-mini",
        "llm_api_key" => form_params["llm_api_key"] || ""
      }
    }

    case %Channel{} |> Channel.changeset(attrs) |> Repo.insert() do
      {:ok, channel} ->
        {:noreply,
         socket
         |> assign(:channels, list_channels())
         |> assign(:show_modal, false)
         |> put_flash(:info, "Channel created successfully")
         |> push_navigate(to: ~p"/channels/#{channel.id}")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Error: #{format_errors(changeset)}")}
    end
  end

  def handle_event("delete_channel", %{"id" => id}, socket) do
    case Repo.get(Channel, id) do
      nil ->
        {:noreply, socket}
      channel ->
        case Repo.delete(channel) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:channels, list_channels())
             |> put_flash(:info, "Channel deleted")}
          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete channel")}
        end
    end
  end

  def handle_event("toggle_active", %{"id" => id}, socket) do
    case Repo.get(Channel, id) do
      nil ->
        {:noreply, socket}
      channel ->
        channel
        |> Channel.changeset(%{is_active: !channel.is_active})
        |> Repo.update()

        # Invalidate cache so webhook uses new settings
        ChatService.Services.Channel.Service.invalidate_cache(channel.channel_id)

        {:noreply, assign(socket, :channels, list_channels())}
    end
  end

  def handle_event("toggle_ai", %{"id" => id}, socket) do
    case Repo.get(Channel, id) do
      nil ->
        {:noreply, socket}
      channel ->
        settings = channel.settings || %{}
        current_ai_enabled = get_in(settings, ["ai_enabled"]) != false
        new_settings = Map.put(settings, "ai_enabled", !current_ai_enabled)

        channel
        |> Channel.changeset(%{settings: new_settings})
        |> Repo.update()

        # Invalidate cache so webhook uses new settings
        ChatService.Services.Channel.Service.invalidate_cache(channel.channel_id)

        {:noreply, assign(socket, :channels, list_channels())}
    end
  end

  defp get_dataset_name(datasets, dataset_id) do
    case Enum.find(datasets, fn d -> d.id == dataset_id end) do
      nil -> "Unknown"
      dataset -> dataset.name
    end
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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex justify-between items-center">
        <h1 class="text-2xl font-bold">LINE OA Channels</h1>
        <button
          phx-click="show_create_modal"
          class="px-4 py-2 bg-orange-500 text-white rounded-lg hover:bg-orange-600 transition"
        >
          + Add Channel
        </button>
      </div>

      <%= if @channels == [] do %>
        <div class="bg-gray-800 rounded-xl border border-gray-700 p-12 text-center">
          <svg class="w-16 h-16 mx-auto text-gray-600 mb-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 12h.01M12 12h.01M16 12h.01M21 12c0 4.418-4.03 8-9 8a9.863 9.863 0 01-4.255-.949L3 20l1.395-3.72C3.512 15.042 3 13.574 3 12c0-4.418 4.03-8 9-8s9 3.582 9 8z"/>
          </svg>
          <h3 class="text-lg font-semibold mb-2">No LINE OA channels yet</h3>
          <p class="text-gray-400 mb-4">Add your first LINE Official Account to start receiving messages</p>
          <button
            phx-click="show_create_modal"
            class="px-4 py-2 bg-orange-500 text-white rounded-lg hover:bg-orange-600 transition"
          >
            Add Channel
          </button>
        </div>
      <% else %>
        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
          <%= for channel <- @channels do %>
            <div class="bg-gray-800 rounded-xl p-6 border border-gray-700 hover:border-gray-600 transition">
              <div class="flex items-start justify-between mb-4">
                <div class="flex-1 min-w-0">
                  <h3 class="font-semibold text-white truncate"><%= channel.name || "Unnamed" %></h3>
                  <p class="text-sm text-gray-400 mt-1 truncate"><%= channel.channel_id %></p>
                </div>
                <div class="flex gap-2 flex-wrap">
                  <span class={if get_in(channel.settings || %{}, ["agent_mode"]) == true, do: "px-2 py-1 rounded text-xs font-semibold bg-blue-500/20 text-blue-400", else: "px-2 py-1 rounded text-xs font-semibold bg-cyan-500/20 text-cyan-400"}>
                    <%= if get_in(channel.settings || %{}, ["agent_mode"]) == true, do: "AGENT", else: "NORMAL" %>
                  </span>
                  <button
                    phx-click="toggle_ai"
                    phx-value-id={channel.id}
                    class={if get_in(channel.settings || %{}, ["ai_enabled"]) != false, do: "px-2 py-1 rounded text-xs font-semibold bg-purple-500/20 text-purple-400 hover:bg-purple-500/30", else: "px-2 py-1 rounded text-xs font-semibold bg-gray-500/20 text-gray-400 hover:bg-gray-500/30"}
                    title="Toggle AI responses"
                  >
                    <%= if get_in(channel.settings || %{}, ["ai_enabled"]) != false, do: "AI ON", else: "AI OFF" %>
                  </button>
                  <button
                    phx-click="toggle_active"
                    phx-value-id={channel.id}
                    class={if channel.is_active, do: "px-2 py-1 rounded text-xs font-semibold bg-green-500/20 text-green-400 hover:bg-green-500/30", else: "px-2 py-1 rounded text-xs font-semibold bg-red-500/20 text-red-400 hover:bg-red-500/30"}
                  >
                    <%= if channel.is_active, do: "ACTIVE", else: "INACTIVE" %>
                  </button>
                </div>
              </div>

              <div class="space-y-2 text-sm mb-4">
                <div class="flex justify-between">
                  <span class="text-gray-400">Provider</span>
                  <span class="text-white"><%= get_in(channel.settings || %{}, ["llm_provider"]) || "openai" %></span>
                </div>
                <div class="flex justify-between">
                  <span class="text-gray-400">Model</span>
                  <span class="text-white"><%= get_in(channel.settings || %{}, ["llm_model"]) || "gpt-4o-mini" %></span>
                </div>
                <div class="flex justify-between">
                  <span class="text-gray-400">Dataset</span>
                  <span class={if channel.dataset_id, do: "text-green-400", else: "text-gray-500"}>
                    <%= if channel.dataset_id do %>
                      <%= get_dataset_name(@datasets, channel.dataset_id) %>
                    <% else %>
                      -
                    <% end %>
                  </span>
                </div>
              </div>

              <div class="p-3 bg-gray-900 rounded-lg">
                <p class="text-xs text-gray-400 mb-1">Webhook URL</p>
                <div class="flex items-center gap-2">
                  <code class="flex-1 text-xs text-orange-400 break-all">/webhook/<%= channel.channel_id %></code>
                  <button
                    type="button"
                    phx-click="copy_webhook"
                    phx-value-url={"/webhook/#{channel.channel_id}"}
                    class="p-1 text-gray-400 hover:text-white"
                    title="Copy"
                  >
                    <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"/>
                    </svg>
                  </button>
                </div>
              </div>

              <div class="flex gap-2 pt-4 border-t border-gray-700">
                <.link
                  navigate={~p"/channels/#{channel.id}"}
                  class="flex-1 px-3 py-2 bg-orange-500 text-white rounded-lg text-sm hover:bg-orange-600 transition text-center"
                >
                  Settings
                </.link>
                <button
                  phx-click="delete_channel"
                  phx-value-id={channel.id}
                  data-confirm="Are you sure you want to delete this channel?"
                  class="px-3 py-2 bg-red-500/20 text-red-400 rounded-lg text-sm hover:bg-red-500/30 transition"
                >
                  Delete
                </button>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>

      <%= if @show_modal do %>
        <div class="fixed inset-0 bg-black/50 flex items-center justify-center z-50 p-4">
          <div class="bg-gray-800 rounded-xl border border-gray-700 p-6 w-full max-w-lg" phx-click-away="close_modal">
            <h2 class="text-xl font-bold mb-4">Add LINE OA Channel</h2>
            <.form for={@form} phx-submit="save_channel" phx-change="validate" class="space-y-4">
              <div>
                <label class="block text-sm font-medium mb-1">Channel Name</label>
                <input
                  type="text"
                  name="name"
                  value={@form.params["name"]}
                  class="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg focus:ring-2 focus:ring-orange-500"
                  placeholder="My LINE OA"
                />
              </div>

              <div>
                <label class="block text-sm font-medium mb-1">Channel ID *</label>
                <input
                  type="text"
                  name="channel_id"
                  value={@form.params["channel_id"]}
                  required
                  class="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg focus:ring-2 focus:ring-orange-500"
                  placeholder="1234567890"
                />
              </div>

              <div>
                <label class="block text-sm font-medium mb-1">Channel Access Token *</label>
                <textarea
                  name="access_token"
                  required
                  rows="2"
                  class="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg focus:ring-2 focus:ring-orange-500 text-sm"
                  placeholder="Long-lived channel access token"
                ><%= @form.params["access_token"] %></textarea>
              </div>

              <div>
                <label class="block text-sm font-medium mb-1">Channel Secret *</label>
                <input
                  type="password"
                  name="channel_secret"
                  value={@form.params["channel_secret"]}
                  required
                  class="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg focus:ring-2 focus:ring-orange-500"
                  placeholder="Channel secret for signature validation"
                />
              </div>

              <div class="p-4 bg-gray-700/30 rounded-lg space-y-4">
                <h3 class="text-sm font-semibold text-orange-400">LLM Configuration</h3>
                <div>
                  <label class="block text-sm font-medium mb-1">Provider</label>
                  <select name="llm_provider" class="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg">
                    <option value="openai" selected={@form.params["llm_provider"] == "openai"}>OpenAI</option>
                    <option value="anthropic" selected={@form.params["llm_provider"] == "anthropic"}>Anthropic</option>
                    <option value="google" selected={@form.params["llm_provider"] == "google"}>Google AI</option>
                    <option value="ollama" selected={@form.params["llm_provider"] == "ollama"}>Ollama (Local)</option>
                    <option value="groq" selected={@form.params["llm_provider"] == "groq"}>Groq</option>
                  </select>
                </div>
                <div>
                  <label class="block text-sm font-medium mb-1">API Key</label>
                  <input
                    type="password"
                    name="llm_api_key"
                    value={@form.params["llm_api_key"]}
                    class="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg"
                    placeholder="sk-..."
                  />
                </div>
                <div>
                  <label class="block text-sm font-medium mb-1">Model</label>
                  <input
                    type="text"
                    name="llm_model"
                    value={@form.params["llm_model"]}
                    class="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg"
                    placeholder="gpt-4o-mini"
                  />
                </div>
              </div>

              <div class="flex items-center gap-2">
                <input
                  type="checkbox"
                  name="is_active"
                  value="true"
                  checked={@form.params["is_active"] == true || @form.params["is_active"] == "true"}
                  class="w-4 h-4 rounded bg-gray-700 border-gray-600"
                />
                <label class="text-sm">Active (receive webhooks)</label>
              </div>

              <p class="text-xs text-gray-400">
                After creating the channel, you can configure additional settings like AI mode, tools, dataset, and system prompt.
              </p>

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
                  Create Channel
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
