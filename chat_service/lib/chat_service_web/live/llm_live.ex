defmodule ChatServiceWeb.LlmLive do
  use ChatServiceWeb, :live_view

  @providers [
    %{
      id: "openai",
      name: "OpenAI",
      logo: "O",
      color: "green",
      models: [
        %{id: "gpt-4o", name: "GPT-4o", tokens: "128K", price: "$2.5/$10"},
        %{id: "gpt-4o-mini", name: "GPT-4o Mini", tokens: "128K", price: "$0.15/$0.6"},
        %{id: "gpt-4-turbo", name: "GPT-4 Turbo", tokens: "128K", price: "$10/$30"}
      ],
      embedding_models: [
        %{id: "text-embedding-3-small", name: "Embedding 3 Small", dim: 1536},
        %{id: "text-embedding-3-large", name: "Embedding 3 Large", dim: 3072}
      ]
    },
    %{
      id: "anthropic",
      name: "Anthropic",
      logo: "A",
      color: "orange",
      models: [
        %{id: "claude-3-5-sonnet-20241022", name: "Claude 3.5 Sonnet", tokens: "200K", price: "$3/$15"},
        %{id: "claude-3-5-haiku-20241022", name: "Claude 3.5 Haiku", tokens: "200K", price: "$1/$5"},
        %{id: "claude-3-opus-20240229", name: "Claude 3 Opus", tokens: "200K", price: "$15/$75"}
      ],
      embedding_models: []
    },
    %{
      id: "google",
      name: "Google AI",
      logo: "G",
      color: "blue",
      models: [
        %{id: "gemini-1.5-pro", name: "Gemini 1.5 Pro", tokens: "2M", price: "$1.25/$5"},
        %{id: "gemini-1.5-flash", name: "Gemini 1.5 Flash", tokens: "1M", price: "$0.075/$0.3"},
        %{id: "gemini-2.0-flash-exp", name: "Gemini 2.0 Flash", tokens: "1M", price: "Free"}
      ],
      embedding_models: [
        %{id: "text-embedding-004", name: "Text Embedding 004", dim: 768}
      ]
    },
    %{
      id: "ollama",
      name: "Ollama (Local)",
      logo: "L",
      color: "purple",
      models: [
        %{id: "llama3.2", name: "Llama 3.2", tokens: "128K", price: "Free"},
        %{id: "llama3.1", name: "Llama 3.1", tokens: "128K", price: "Free"},
        %{id: "mistral", name: "Mistral", tokens: "32K", price: "Free"},
        %{id: "qwen2.5", name: "Qwen 2.5", tokens: "128K", price: "Free"}
      ],
      embedding_models: [
        %{id: "nomic-embed-text", name: "Nomic Embed", dim: 768},
        %{id: "mxbai-embed-large", name: "MXBai Embed Large", dim: 1024}
      ]
    },
    %{
      id: "groq",
      name: "Groq",
      logo: "Q",
      color: "red",
      models: [
        %{id: "llama-3.3-70b-versatile", name: "Llama 3.3 70B", tokens: "128K", price: "$0.59/$0.79"},
        %{id: "llama-3.1-8b-instant", name: "Llama 3.1 8B", tokens: "128K", price: "$0.05/$0.08"},
        %{id: "mixtral-8x7b-32768", name: "Mixtral 8x7B", tokens: "32K", price: "$0.24/$0.24"}
      ],
      embedding_models: []
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "LLM Settings")
     |> assign(:providers, @providers)
     |> assign(:selected_provider, nil)
     |> assign(:config, load_config())}
  end

  @impl true
  def handle_event("select_provider", %{"id" => id}, socket) do
    provider = Enum.find(@providers, fn p -> p.id == id end)
    {:noreply, assign(socket, :selected_provider, provider)}
  end

  def handle_event("save_config", params, socket) do
    config = %{
      default_provider: params["default_provider"],
      default_model: params["default_model"],
      embedding_provider: params["embedding_provider"],
      embedding_model: params["embedding_model"],
      api_keys: %{
        openai: params["openai_key"] || "",
        anthropic: params["anthropic_key"] || "",
        google: params["google_key"] || "",
        groq: params["groq_key"] || ""
      }
    }

    # In production, save to database or config file
    {:noreply,
     socket
     |> assign(:config, config)
     |> put_flash(:info, "Configuration saved")}
  end

  defp load_config do
    %{
      default_provider: "openai",
      default_model: "gpt-4o-mini",
      embedding_provider: "openai",
      embedding_model: "text-embedding-3-small",
      api_keys: %{
        openai: "",
        anthropic: "",
        google: "",
        groq: ""
      }
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex justify-between items-center">
        <h1 class="text-2xl font-bold">LLM Settings</h1>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <div class="bg-gray-800 rounded-xl border border-gray-700 p-6">
          <h2 class="text-lg font-semibold mb-4">Available Providers</h2>
          <div class="space-y-3">
            <%= for provider <- @providers do %>
              <div
                class={"p-4 rounded-lg border cursor-pointer transition #{if @selected_provider && @selected_provider.id == provider.id, do: "border-orange-500 bg-orange-500/10", else: "border-gray-700 hover:border-gray-600"}"}
                phx-click="select_provider"
                phx-value-id={provider.id}
              >
                <div class="flex items-center gap-3">
                  <div class={"w-10 h-10 rounded-lg flex items-center justify-center font-bold text-lg bg-#{provider.color}-500/20 text-#{provider.color}-400"}>
                    <%= provider.logo %>
                  </div>
                  <div class="flex-1">
                    <p class="font-medium"><%= provider.name %></p>
                    <p class="text-sm text-gray-400"><%= length(provider.models) %> models</p>
                  </div>
                  <svg class="w-5 h-5 text-gray-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7"/>
                  </svg>
                </div>
              </div>
            <% end %>
          </div>
        </div>

        <div class="bg-gray-800 rounded-xl border border-gray-700 p-6">
          <%= if @selected_provider do %>
            <h2 class="text-lg font-semibold mb-4"><%= @selected_provider.name %> Models</h2>
            <div class="space-y-4">
              <div>
                <h3 class="text-sm font-medium text-gray-400 mb-2">Chat Models</h3>
                <div class="space-y-2">
                  <%= for model <- @selected_provider.models do %>
                    <div class="p-3 bg-gray-700/50 rounded-lg">
                      <div class="flex justify-between items-center">
                        <span class="font-medium"><%= model.name %></span>
                        <span class="text-sm text-gray-400"><%= model.price %></span>
                      </div>
                      <div class="text-xs text-gray-500 mt-1">
                        <%= model.id %> - <%= model.tokens %> tokens
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>

              <%= if @selected_provider.embedding_models != [] do %>
                <div>
                  <h3 class="text-sm font-medium text-gray-400 mb-2">Embedding Models</h3>
                  <div class="space-y-2">
                    <%= for model <- @selected_provider.embedding_models do %>
                      <div class="p-3 bg-gray-700/50 rounded-lg">
                        <div class="flex justify-between items-center">
                          <span class="font-medium"><%= model.name %></span>
                          <span class="text-sm text-gray-400"><%= model.dim %>d</span>
                        </div>
                        <div class="text-xs text-gray-500 mt-1"><%= model.id %></div>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          <% else %>
            <div class="flex items-center justify-center h-64 text-gray-500">
              Select a provider to view models
            </div>
          <% end %>
        </div>
      </div>

      <div class="bg-gray-800 rounded-xl border border-gray-700 p-6">
        <h2 class="text-lg font-semibold mb-4">Configuration</h2>
        <.form for={%{}} phx-submit="save_config" class="space-y-6">
          <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
            <div>
              <label class="block text-sm font-medium mb-1">Default Chat Provider</label>
              <select name="default_provider" class="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg">
                <%= for provider <- @providers do %>
                  <option value={provider.id} selected={@config.default_provider == provider.id}>
                    <%= provider.name %>
                  </option>
                <% end %>
              </select>
            </div>
            <div>
              <label class="block text-sm font-medium mb-1">Default Chat Model</label>
              <input
                type="text"
                name="default_model"
                value={@config.default_model}
                class="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg"
              />
            </div>
            <div>
              <label class="block text-sm font-medium mb-1">Embedding Provider</label>
              <select name="embedding_provider" class="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg">
                <%= for provider <- @providers, provider.embedding_models != [] do %>
                  <option value={provider.id} selected={@config.embedding_provider == provider.id}>
                    <%= provider.name %>
                  </option>
                <% end %>
              </select>
            </div>
            <div>
              <label class="block text-sm font-medium mb-1">Embedding Model</label>
              <input
                type="text"
                name="embedding_model"
                value={@config.embedding_model}
                class="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg"
              />
            </div>
          </div>

          <div>
            <h3 class="text-sm font-medium mb-3">API Keys</h3>
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div>
                <label class="block text-xs text-gray-400 mb-1">OpenAI API Key</label>
                <input
                  type="password"
                  name="openai_key"
                  placeholder="sk-..."
                  class="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg text-sm"
                />
              </div>
              <div>
                <label class="block text-xs text-gray-400 mb-1">Anthropic API Key</label>
                <input
                  type="password"
                  name="anthropic_key"
                  placeholder="sk-ant-..."
                  class="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg text-sm"
                />
              </div>
              <div>
                <label class="block text-xs text-gray-400 mb-1">Google AI API Key</label>
                <input
                  type="password"
                  name="google_key"
                  placeholder="AIza..."
                  class="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg text-sm"
                />
              </div>
              <div>
                <label class="block text-xs text-gray-400 mb-1">Groq API Key</label>
                <input
                  type="password"
                  name="groq_key"
                  placeholder="gsk_..."
                  class="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg text-sm"
                />
              </div>
            </div>
          </div>

          <div class="flex justify-end">
            <button
              type="submit"
              class="px-6 py-2 bg-orange-500 text-white rounded-lg hover:bg-orange-600 transition"
            >
              Save Configuration
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end
end
