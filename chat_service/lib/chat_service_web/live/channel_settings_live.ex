defmodule ChatServiceWeb.ChannelSettingsLive do
  use ChatServiceWeb, :live_view

  alias ChatService.Repo
  alias ChatService.Schemas.Channel
  alias ChatService.VectorService.Client, as: VectorClient
  import Ecto.Query

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Repo.get(Channel, id) |> Repo.preload(:dataset) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Channel not found")
         |> push_navigate(to: ~p"/channels")}

      channel ->
        # Get actual document count from vector service if dataset is linked
        dataset_stats = get_dataset_stats(channel.dataset)

        {:ok,
         socket
         |> assign(:page_title, channel.name || "Channel Settings")
         |> assign(:channel, channel)
         |> assign(:dataset_stats, dataset_stats)
         |> assign(:datasets, list_datasets())
         |> assign(:available_skills, get_available_skills())
         |> assign(:available_models, [])
         |> assign(:loading_models, false)
         |> assign(:active_tab, "general")
         |> assign(:form, to_form(channel_to_form(channel)))}
    end
  end

  defp get_dataset_stats(nil), do: %{total_vectors: 0}
  defp get_dataset_stats(dataset) do
    case VectorClient.get_stats(dataset.collection_name) do
      {:ok, stats} -> %{total_vectors: stats["total_vectors"] || 0}
      _ -> %{total_vectors: 0}
    end
  end

  defp channel_to_form(channel) do
    settings = channel.settings || %{}
    %{
      "name" => channel.name || "",
      "channel_id" => channel.channel_id,
      "access_token" => channel.access_token || "",
      "channel_secret" => channel.channel_secret || "",
      "is_active" => channel.is_active,
      "ai_enabled" => get_in(settings, ["ai_enabled"]) != false,
      "agent_mode" => get_in(settings, ["agent_mode"]) == true,
      "selected_skills" => get_in(settings, ["selected_skills"]) || [],
      "llm_provider" => get_in(settings, ["llm_provider"]) || "openai",
      "llm_model" => get_in(settings, ["llm_model"]) || "gpt-4o-mini",
      "llm_api_key" => get_in(settings, ["llm_api_key"]) || "",
      "system_prompt" => get_in(settings, ["system_prompt"]) || "",
      "dataset_id" => channel.dataset_id || "",
      "max_tokens" => get_in(settings, ["max_tokens"]) || "",
      "temperature" => get_in(settings, ["temperature"]) || "0.7",
      "rag_confidence" => get_in(settings, ["rag_confidence"]) || "50",
      "rag_top_k" => get_in(settings, ["rag_top_k"]) || "3"
    }
  end

  defp list_datasets do
    ChatService.Schemas.Dataset
    |> where([d], d.is_active == true)
    |> order_by([d], asc: d.name)
    |> Repo.all()
    |> Enum.map(fn dataset ->
      # Get actual vector count from vector service
      vector_count = case VectorClient.get_stats(dataset.collection_name) do
        {:ok, stats} -> stats["total_vectors"] || 0
        _ -> 0
      end
      Map.put(dataset, :vector_count, vector_count)
    end)
  end

  defp get_available_skills do
    ChatService.Agents.Tools.Registry.available_skills()
  rescue
    _ -> []
  end

  @impl true
  def handle_event("change_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_event("validate", params, socket) do
    # Get the target field that changed
    target = params["_target"] || []

    # Filter out LiveView internal params
    new_params = Map.drop(params, ["_target", "_csrf_token"])

    # Handle checkboxes - if target is a checkbox field and not in params, it was unchecked
    checkbox_fields = ["is_active", "ai_enabled", "agent_mode"]
    form_params = socket.assigns.form.params

    form_params = Enum.reduce(checkbox_fields, form_params, fn field, acc ->
      if field in target and not Map.has_key?(new_params, field) do
        # Checkbox was unchecked
        Map.put(acc, field, false)
      else
        acc
      end
    end)

    # Merge new params
    form_params = Map.merge(form_params, new_params)

    {:noreply, assign(socket, :form, to_form(form_params))}
  end

  def handle_event("fetch_models", %{"provider" => provider, "api_key" => api_key}, socket) do
    if api_key != "" do
      socket = assign(socket, :loading_models, true)
      send(self(), {:fetch_models, provider, api_key})
      {:noreply, socket}
    else
      {:noreply, assign(socket, :available_models, [])}
    end
  end

  def handle_event("save_settings", _params, socket) do
    channel = socket.assigns.channel
    form_params = socket.assigns.form.params

    dataset_id = case form_params["dataset_id"] do
      "" -> nil
      nil -> nil
      id -> id
    end

    selected_skills = parse_selected_skills(form_params)

    attrs = %{
      name: form_params["name"],
      channel_id: form_params["channel_id"],
      access_token: form_params["access_token"],
      channel_secret: form_params["channel_secret"],
      is_active: form_params["is_active"] == true || form_params["is_active"] == "true",
      dataset_id: dataset_id,
      settings: %{
        "ai_enabled" => form_params["ai_enabled"] == true || form_params["ai_enabled"] == "true",
        "agent_mode" => form_params["agent_mode"] == true || form_params["agent_mode"] == "true",
        "selected_skills" => selected_skills,
        "llm_provider" => form_params["llm_provider"],
        "llm_model" => form_params["llm_model"],
        "llm_api_key" => form_params["llm_api_key"],
        "system_prompt" => form_params["system_prompt"],
        "max_tokens" => form_params["max_tokens"],
        "temperature" => form_params["temperature"],
        "rag_confidence" => form_params["rag_confidence"] || "50",
        "rag_top_k" => form_params["rag_top_k"] || "3"
      }
    }

    case channel |> Channel.changeset(attrs) |> Repo.update() do
      {:ok, updated_channel} ->
        # Invalidate channel cache so webhook uses new settings immediately
        ChatService.Services.Channel.Service.invalidate_cache(updated_channel.channel_id)

        updated_channel = Repo.preload(updated_channel, :dataset)
        {:noreply,
         socket
         |> assign(:channel, updated_channel)
         |> assign(:form, to_form(channel_to_form(updated_channel)))
         |> put_flash(:info, "Settings saved successfully")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Error: #{format_errors(changeset)}")}
    end
  end

  def handle_event("toggle_skill", %{"skill" => skill_id}, socket) do
    form_params = socket.assigns.form.params
    current_skills = form_params["selected_skills"] || []

    new_skills = if skill_id in current_skills do
      List.delete(current_skills, skill_id)
    else
      [skill_id | current_skills]
    end

    new_params = Map.put(form_params, "selected_skills", new_skills)
    {:noreply, assign(socket, :form, to_form(new_params))}
  end

  defp parse_selected_skills(params) do
    case params["selected_skills"] do
      nil -> []
      skills when is_list(skills) -> skills
      skills when is_binary(skills) -> [skills]
      _ -> []
    end
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
      _ -> []
    end
  end

  defp fetch_models_from_provider("anthropic", api_key) do
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
      _ -> []
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
      _ -> []
    end
  end

  defp fetch_models_from_provider("ollama", _api_key) do
    case Req.get("http://localhost:11434/api/tags", receive_timeout: 5_000) do
      {:ok, %{status: 200, body: %{"models" => models}}} ->
        models |> Enum.map(fn m -> %{id: m["name"], name: m["name"]} end)
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
      <div class="flex items-center gap-4 mb-6">
        <.link navigate={~p"/channels"} class="text-gray-400 hover:text-white">
          <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7"/>
          </svg>
        </.link>
        <div class="flex-1">
          <h1 class="text-2xl font-bold"><%= @channel.name || "Unnamed Channel" %></h1>
          <p class="text-sm text-gray-400"><%= @channel.channel_id %></p>
        </div>
        <div class="flex gap-2">
          <span class={if @channel.is_active, do: "px-3 py-1 rounded-full text-sm font-semibold bg-green-500/20 text-green-400", else: "px-3 py-1 rounded-full text-sm font-semibold bg-red-500/20 text-red-400"}>
            <%= if @channel.is_active, do: "Active", else: "Inactive" %>
          </span>
          <span class={if get_in(@channel.settings || %{}, ["agent_mode"]) == true, do: "px-3 py-1 rounded-full text-sm font-semibold bg-blue-500/20 text-blue-400", else: "px-3 py-1 rounded-full text-sm font-semibold bg-cyan-500/20 text-cyan-400"}>
            <%= if get_in(@channel.settings || %{}, ["agent_mode"]) == true, do: "Agent Mode", else: "Normal Mode" %>
          </span>
        </div>
      </div>

      <div class="flex gap-2 border-b border-gray-700 mb-6">
        <button
          phx-click="change_tab"
          phx-value-tab="general"
          class={"px-4 py-2 text-sm font-medium border-b-2 transition #{if @active_tab == "general", do: "border-orange-500 text-orange-400", else: "border-transparent text-gray-400 hover:text-white"}"}
        >
          General
        </button>
        <button
          phx-click="change_tab"
          phx-value-tab="line"
          class={"px-4 py-2 text-sm font-medium border-b-2 transition #{if @active_tab == "line", do: "border-orange-500 text-orange-400", else: "border-transparent text-gray-400 hover:text-white"}"}
        >
          LINE API
        </button>
        <button
          phx-click="change_tab"
          phx-value-tab="ai"
          class={"px-4 py-2 text-sm font-medium border-b-2 transition #{if @active_tab == "ai", do: "border-orange-500 text-orange-400", else: "border-transparent text-gray-400 hover:text-white"}"}
        >
          AI Settings
        </button>
        <button
          phx-click="change_tab"
          phx-value-tab="tools"
          class={"px-4 py-2 text-sm font-medium border-b-2 transition #{if @active_tab == "tools", do: "border-orange-500 text-orange-400", else: "border-transparent text-gray-400 hover:text-white"}"}
        >
          Tools & Skills
        </button>
        <button
          phx-click="change_tab"
          phx-value-tab="dataset"
          class={"px-4 py-2 text-sm font-medium border-b-2 transition #{if @active_tab == "dataset", do: "border-orange-500 text-orange-400", else: "border-transparent text-gray-400 hover:text-white"}"}
        >
          Dataset
        </button>
      </div>

      <.form for={@form} phx-submit="save_settings" phx-change="validate">
        <%= if @active_tab == "general" do %>
          <div class="bg-gray-800 rounded-xl border border-gray-700 p-6 space-y-6">
            <h2 class="text-lg font-semibold text-white mb-4">General Settings</h2>

            <div class="grid grid-cols-2 gap-6">
              <div>
                <label class="block text-sm font-medium mb-2">Channel Name</label>
                <input
                  type="text"
                  name="name"
                  value={@form.params["name"]}
                  class="w-full px-4 py-3 bg-gray-700 border border-gray-600 rounded-lg focus:ring-2 focus:ring-orange-500"
                  placeholder="My LINE OA"
                />
              </div>

              <div>
                <label class="block text-sm font-medium mb-2">Channel ID</label>
                <input
                  type="text"
                  name="channel_id"
                  value={@form.params["channel_id"]}
                  class="w-full px-4 py-3 bg-gray-700 border border-gray-600 rounded-lg focus:ring-2 focus:ring-orange-500"
                  placeholder="1234567890"
                  readonly
                />
              </div>
            </div>

            <div class="flex gap-6">
              <label class="flex items-center gap-3 cursor-pointer">
                <input
                  type="checkbox"
                  name="is_active"
                  value="true"
                  checked={@form.params["is_active"] == true || @form.params["is_active"] == "true"}
                  class="w-5 h-5 rounded bg-gray-700 border-gray-600 accent-green-500"
                />
                <span class="text-sm">Active (Receive Webhooks)</span>
              </label>
              <label class="flex items-center gap-3 cursor-pointer">
                <input
                  type="checkbox"
                  name="ai_enabled"
                  value="true"
                  checked={@form.params["ai_enabled"] == true || @form.params["ai_enabled"] == "true"}
                  class="w-5 h-5 rounded bg-gray-700 border-gray-600 accent-purple-500"
                />
                <span class="text-sm">Enable AI Responses</span>
              </label>
            </div>

            <div class="p-4 bg-gray-700/30 rounded-lg">
              <h3 class="text-sm font-semibold text-yellow-400 mb-2">Webhook URL</h3>
              <div class="flex items-center gap-2">
                <code class="flex-1 text-sm text-orange-400 bg-gray-900/50 p-3 rounded break-all">/webhook/<%= @channel.channel_id %></code>
                <button type="button" class="px-3 py-2 bg-gray-600 text-white rounded hover:bg-gray-500 text-sm">
                  Copy
                </button>
              </div>
              <p class="text-xs text-gray-400 mt-2">Configure this URL in your LINE Developer Console</p>
            </div>
          </div>
        <% end %>

        <%= if @active_tab == "line" do %>
          <div class="bg-gray-800 rounded-xl border border-gray-700 p-6 space-y-6">
            <h2 class="text-lg font-semibold text-white mb-4">LINE API Configuration</h2>

            <div>
              <label class="block text-sm font-medium mb-2">Channel Access Token</label>
              <textarea
                name="access_token"
                rows="3"
                class="w-full px-4 py-3 bg-gray-700 border border-gray-600 rounded-lg focus:ring-2 focus:ring-orange-500 font-mono text-sm"
                placeholder="Long-lived channel access token from LINE Developer Console"
              ><%= @form.params["access_token"] %></textarea>
              <p class="text-xs text-gray-400 mt-1">Get this from LINE Developer Console > Your Channel > Messaging API</p>
            </div>

            <div>
              <label class="block text-sm font-medium mb-2">Channel Secret</label>
              <input
                type="password"
                name="channel_secret"
                value={@form.params["channel_secret"]}
                class="w-full px-4 py-3 bg-gray-700 border border-gray-600 rounded-lg focus:ring-2 focus:ring-orange-500 font-mono"
                placeholder="Channel secret for signature validation"
              />
              <p class="text-xs text-gray-400 mt-1">Used to verify webhook requests from LINE</p>
            </div>

            <div class="p-4 bg-blue-500/10 border border-blue-500/30 rounded-lg">
              <h3 class="text-sm font-semibold text-blue-400 mb-2">LINE Developer Console Setup</h3>
              <ol class="text-sm text-gray-300 space-y-2 list-decimal list-inside">
                <li>Go to <a href="https://developers.line.biz/console/" target="_blank" class="text-blue-400 hover:underline">LINE Developer Console</a></li>
                <li>Select your Messaging API channel</li>
                <li>Copy the Channel ID and paste it above</li>
                <li>Copy the Channel Access Token (issue one if needed)</li>
                <li>Copy the Channel Secret from Basic Settings</li>
                <li>Set the Webhook URL to: <code class="text-orange-400">/webhook/<%= @channel.channel_id %></code></li>
              </ol>
            </div>
          </div>
        <% end %>

        <%= if @active_tab == "ai" do %>
          <div class="bg-gray-800 rounded-xl border border-gray-700 p-6 space-y-6">
            <h2 class="text-lg font-semibold text-white mb-4">AI & LLM Configuration</h2>

            <div class="p-4 bg-gray-700/30 rounded-lg mb-6">
              <label class="flex items-center gap-3 cursor-pointer">
                <input
                  type="checkbox"
                  name="agent_mode"
                  value="true"
                  checked={@form.params["agent_mode"] == true || @form.params["agent_mode"] == "true"}
                  class="w-5 h-5 rounded bg-gray-700 border-gray-600 accent-blue-500"
                />
                <div>
                  <span class="text-sm font-medium">Agent Mode</span>
                  <p class="text-xs text-gray-400 mt-1">Enable tools/skills for AI (search_faq, web_scraper, etc.)</p>
                </div>
              </label>
              <div class="mt-4 p-3 bg-gray-900/50 rounded text-sm">
                <%= if @form.params["agent_mode"] == true || @form.params["agent_mode"] == "true" do %>
                  <p class="text-blue-400">Agent Mode: AI will use tools to find information before answering</p>
                <% else %>
                  <p class="text-cyan-400">Normal Mode: AI will use System Prompt + RAG context directly</p>
                <% end %>
              </div>
            </div>

            <div class="grid grid-cols-2 gap-6">
              <div>
                <label class="block text-sm font-medium mb-2">LLM Provider</label>
                <select name="llm_provider" class="w-full px-4 py-3 bg-gray-700 border border-gray-600 rounded-lg">
                  <option value="openai" selected={@form.params["llm_provider"] == "openai"}>OpenAI</option>
                  <option value="anthropic" selected={@form.params["llm_provider"] == "anthropic"}>Anthropic</option>
                  <option value="google" selected={@form.params["llm_provider"] == "google"}>Google AI</option>
                  <option value="groq" selected={@form.params["llm_provider"] == "groq"}>Groq</option>
                  <option value="ollama" selected={@form.params["llm_provider"] == "ollama"}>Ollama (Local)</option>
                </select>
              </div>

              <div>
                <label class="block text-sm font-medium mb-2">API Key</label>
                <div class="flex gap-2">
                  <input
                    type="password"
                    name="llm_api_key"
                    value={@form.params["llm_api_key"]}
                    class="flex-1 px-4 py-3 bg-gray-700 border border-gray-600 rounded-lg font-mono"
                    placeholder="sk-..."
                  />
                  <button
                    type="button"
                    phx-click="fetch_models"
                    phx-value-provider={@form.params["llm_provider"] || "openai"}
                    phx-value-api_key={@form.params["llm_api_key"] || ""}
                    class="px-4 py-3 bg-blue-500 text-white rounded-lg hover:bg-blue-600 transition disabled:opacity-50"
                    disabled={@loading_models || (@form.params["llm_api_key"] || "") == ""}
                  >
                    <%= if @loading_models, do: "Loading...", else: "Load Models" %>
                  </button>
                </div>
              </div>
            </div>

            <div>
              <label class="block text-sm font-medium mb-2">Model</label>
              <%= if @available_models != [] do %>
                <select name="llm_model" class="w-full px-4 py-3 bg-gray-700 border border-gray-600 rounded-lg">
                  <%= for model <- @available_models do %>
                    <option value={model.id} selected={@form.params["llm_model"] == model.id}>
                      <%= model.name %>
                    </option>
                  <% end %>
                </select>
              <% else %>
                <input
                  type="text"
                  name="llm_model"
                  value={@form.params["llm_model"]}
                  class="w-full px-4 py-3 bg-gray-700 border border-gray-600 rounded-lg"
                  placeholder="gpt-4o-mini"
                />
                <p class="text-xs text-gray-400 mt-1">Enter API key and click "Load Models" to see available models</p>
              <% end %>
            </div>

            <div class="grid grid-cols-2 gap-6">
              <div>
                <label class="block text-sm font-medium mb-2">Max Tokens</label>
                <input
                  type="number"
                  name="max_tokens"
                  value={@form.params["max_tokens"]}
                  class="w-full px-4 py-3 bg-gray-700 border border-gray-600 rounded-lg"
                  placeholder="Default"
                  min="100"
                  max="128000"
                />
                <p class="text-xs text-gray-400 mt-1">Leave empty for default</p>
              </div>
              <div>
                <label class="block text-sm font-medium mb-2">Temperature</label>
                <input
                  type="number"
                  name="temperature"
                  value={@form.params["temperature"]}
                  class="w-full px-4 py-3 bg-gray-700 border border-gray-600 rounded-lg"
                  placeholder="0.7"
                  min="0"
                  max="2"
                  step="0.1"
                />
                <p class="text-xs text-gray-400 mt-1">0 = deterministic, 2 = creative</p>
              </div>
            </div>

            <div>
              <label class="block text-sm font-medium mb-2">System Prompt</label>
              <textarea
                name="system_prompt"
                rows="5"
                class="w-full px-4 py-3 bg-gray-700 border border-gray-600 rounded-lg focus:ring-2 focus:ring-orange-500"
                placeholder="You are a helpful assistant for our LINE Official Account..."
              ><%= @form.params["system_prompt"] %></textarea>
              <p class="text-xs text-gray-400 mt-1">Customize AI behavior and personality</p>
            </div>
          </div>
        <% end %>

        <%= if @active_tab == "tools" do %>
          <div class="bg-gray-800 rounded-xl border border-gray-700 p-6 space-y-6">
            <h2 class="text-lg font-semibold text-white mb-4">Tools & Skills</h2>

            <%= if @form.params["agent_mode"] != true && @form.params["agent_mode"] != "true" do %>
              <div class="p-4 bg-yellow-500/10 border border-yellow-500/30 rounded-lg">
                <p class="text-yellow-400 text-sm">
                  Tools are only available in Agent Mode. Enable Agent Mode in AI Settings to use tools.
                </p>
              </div>
            <% else %>
              <p class="text-gray-400 text-sm mb-4">
                Select which tools/skills the AI can use when answering questions.
              </p>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <%= for skill <- @available_skills do %>
                  <label class={"flex items-start gap-3 p-4 rounded-lg cursor-pointer transition #{if skill.id in (@form.params["selected_skills"] || []), do: "bg-blue-500/20 border-2 border-blue-500", else: "bg-gray-700/30 border-2 border-transparent hover:border-gray-600"}"}>
                    <input
                      type="checkbox"
                      name="selected_skills[]"
                      value={skill.id}
                      checked={skill.id in (@form.params["selected_skills"] || [])}
                      class="w-5 h-5 rounded bg-gray-700 border-gray-600 accent-blue-500 mt-0.5"
                    />
                    <div class="flex-1">
                      <span class="font-medium text-white"><%= skill.name %></span>
                      <p class="text-sm text-gray-400 mt-1"><%= skill.description %></p>
                      <span class={"text-xs px-2 py-0.5 rounded mt-2 inline-block #{if skill.enabled, do: "bg-green-500/20 text-green-400", else: "bg-red-500/20 text-red-400"}"}>
                        <%= if skill.enabled, do: "Enabled", else: "Disabled" %>
                      </span>
                    </div>
                  </label>
                <% end %>
              </div>

              <%= if @channel.dataset do %>
                <div class="p-4 bg-green-500/10 border border-green-500/30 rounded-lg mt-4">
                  <div class="flex items-center gap-2">
                    <svg class="w-5 h-5 text-green-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7"/>
                    </svg>
                    <span class="text-green-400 font-medium">search_faq</span>
                    <span class="text-xs text-gray-400">- Auto-enabled (Dataset linked)</span>
                  </div>
                  <p class="text-sm text-gray-300 mt-2">
                    This tool is automatically available because you have linked a dataset.
                  </p>
                </div>
              <% end %>
            <% end %>
          </div>
        <% end %>

        <%= if @active_tab == "dataset" do %>
          <div class="bg-gray-800 rounded-xl border border-gray-700 p-6 space-y-6">
            <h2 class="text-lg font-semibold text-white mb-4">Dataset & RAG</h2>

            <div>
              <label class="block text-sm font-medium mb-2">Linked Dataset</label>
              <select name="dataset_id" class="w-full px-4 py-3 bg-gray-700 border border-gray-600 rounded-lg">
                <option value="">-- No Dataset (RAG Disabled) --</option>
                <%= for dataset <- @datasets do %>
                  <option value={dataset.id} selected={@form.params["dataset_id"] == to_string(dataset.id)}>
                    <%= dataset.name %> (<%= dataset.vector_count %> documents)
                  </option>
                <% end %>
              </select>
              <p class="text-xs text-gray-400 mt-1">Link a dataset to enable FAQ/RAG search functionality</p>
            </div>

            <!-- Embedding/RAG Settings -->
            <div class="p-4 bg-gray-700/30 rounded-lg">
              <h3 class="text-sm font-semibold text-purple-400 mb-4">Embedding Settings</h3>
              <div class="grid grid-cols-2 gap-6">
                <div>
                  <label class="block text-sm font-medium mb-2">Confidence Threshold (%)</label>
                  <div class="flex items-center gap-3">
                    <input
                      type="range"
                      name="rag_confidence"
                      min="0"
                      max="100"
                      step="5"
                      value={@form.params["rag_confidence"] || "50"}
                      class="flex-1 h-2 bg-gray-600 rounded-lg appearance-none cursor-pointer accent-purple-500"
                    />
                    <span class="text-purple-400 font-mono w-12 text-right"><%= @form.params["rag_confidence"] || "50" %>%</span>
                  </div>
                  <p class="text-xs text-gray-400 mt-1">Minimum similarity score to include results (0-100%)</p>
                </div>
                <div>
                  <label class="block text-sm font-medium mb-2">Number of Results (Top-K)</label>
                  <select name="rag_top_k" class="w-full px-4 py-3 bg-gray-700 border border-gray-600 rounded-lg">
                    <%= for k <- [1, 2, 3, 5, 10, 15, 20] do %>
                      <option value={k} selected={to_string(@form.params["rag_top_k"] || "3") == to_string(k)}>
                        <%= k %> results
                      </option>
                    <% end %>
                  </select>
                  <p class="text-xs text-gray-400 mt-1">How many similar documents to retrieve</p>
                </div>
              </div>
            </div>

            <%= if @channel.dataset do %>
              <div class="p-4 bg-gray-700/30 rounded-lg">
                <h3 class="text-sm font-semibold text-green-400 mb-3">Current Dataset</h3>
                <div class="grid grid-cols-2 gap-4 text-sm">
                  <div>
                    <span class="text-gray-400">Name:</span>
                    <span class="text-white ml-2"><%= @channel.dataset.name %></span>
                  </div>
                  <div>
                    <span class="text-gray-400">Documents:</span>
                    <span class="text-white ml-2"><%= @dataset_stats.total_vectors %></span>
                  </div>
                  <div>
                    <span class="text-gray-400">Collection:</span>
                    <span class="text-white ml-2 font-mono text-xs"><%= @channel.dataset.collection_name %></span>
                  </div>
                  <div>
                    <span class="text-gray-400">Dimension:</span>
                    <span class="text-white ml-2"><%= @channel.dataset.dimension %></span>
                  </div>
                </div>
                <div class="mt-4">
                  <.link navigate={~p"/datasets/#{@channel.dataset.id}"} class="text-orange-400 hover:text-orange-300 text-sm">
                    View Dataset Details &rarr;
                  </.link>
                </div>
              </div>

              <div class="p-4 bg-blue-500/10 border border-blue-500/30 rounded-lg">
                <h3 class="text-sm font-semibold text-blue-400 mb-2">How RAG Works</h3>
                <p class="text-sm text-gray-300">
                  <%= if @form.params["agent_mode"] == true || @form.params["agent_mode"] == "true" do %>
                    <strong>Agent Mode:</strong> When a user asks a question, the AI will use the <code class="text-blue-400">search_faq</code> tool to find relevant information from the dataset before answering.
                  <% else %>
                    <strong>Normal Mode:</strong> When a user asks a question, we automatically search the dataset and include relevant results in the AI's context to help generate better answers.
                  <% end %>
                </p>
              </div>
            <% else %>
              <div class="p-4 bg-yellow-500/10 border border-yellow-500/30 rounded-lg">
                <p class="text-yellow-400 text-sm">
                  No dataset linked. Link a dataset above to enable FAQ/RAG search functionality.
                </p>
                <.link navigate={~p"/datasets"} class="text-orange-400 hover:text-orange-300 text-sm mt-2 inline-block">
                  Create a new dataset &rarr;
                </.link>
              </div>
            <% end %>
          </div>
        <% end %>

        <div class="flex justify-end gap-4 mt-6">
          <.link navigate={~p"/channels"} class="px-6 py-3 bg-gray-700 text-white rounded-lg hover:bg-gray-600 transition">
            Cancel
          </.link>
          <button
            type="submit"
            class="px-6 py-3 bg-orange-500 text-white rounded-lg hover:bg-orange-600 transition"
          >
            Save Changes
          </button>
        </div>
      </.form>
    </div>
    """
  end
end
