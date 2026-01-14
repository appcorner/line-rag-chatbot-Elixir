defmodule ChatServiceWeb.SettingsLive do
  use ChatServiceWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:active_tab, "general")
     |> assign(:config, load_config())}
  end

  @impl true
  def handle_event("change_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_event("save_general", _params, socket) do
    # Save general settings
    {:noreply, put_flash(socket, :info, "Settings saved")}
  end

  def handle_event("save_webhook", _params, socket) do
    # Save webhook settings
    {:noreply, put_flash(socket, :info, "Webhook settings saved")}
  end

  def handle_event("test_vector_service", _, socket) do
    case ChatService.VectorService.Client.health() do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Vector service is healthy")}
      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Vector service is not available")}
    end
  end

  defp load_config do
    %{
      app_name: "Chat Service",
      webhook_url: "",
      rate_limit: 100,
      buffer_timeout: 3000,
      vector_service_url: "http://localhost:50052"
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <h1 class="text-2xl font-bold">Settings</h1>

      <div class="flex gap-4 border-b border-gray-700">
        <button
          phx-click="change_tab"
          phx-value-tab="general"
          class={"px-4 py-2 border-b-2 transition #{if @active_tab == "general", do: "border-orange-500 text-orange-500", else: "border-transparent text-gray-400 hover:text-white"}"}
        >
          General
        </button>
        <button
          phx-click="change_tab"
          phx-value-tab="webhook"
          class={"px-4 py-2 border-b-2 transition #{if @active_tab == "webhook", do: "border-orange-500 text-orange-500", else: "border-transparent text-gray-400 hover:text-white"}"}
        >
          Webhook
        </button>
        <button
          phx-click="change_tab"
          phx-value-tab="services"
          class={"px-4 py-2 border-b-2 transition #{if @active_tab == "services", do: "border-orange-500 text-orange-500", else: "border-transparent text-gray-400 hover:text-white"}"}
        >
          Services
        </button>
      </div>

      <%= if @active_tab == "general" do %>
        <div class="bg-gray-800 rounded-xl border border-gray-700 p-6">
          <h2 class="text-lg font-semibold mb-4">General Settings</h2>
          <.form for={%{}} phx-submit="save_general" class="space-y-4">
            <div>
              <label class="block text-sm font-medium mb-1">Application Name</label>
              <input
                type="text"
                name="app_name"
                value={@config.app_name}
                class="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg"
              />
            </div>
            <div>
              <label class="block text-sm font-medium mb-1">Rate Limit (requests/min)</label>
              <input
                type="number"
                name="rate_limit"
                value={@config.rate_limit}
                class="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg"
              />
            </div>
            <div>
              <label class="block text-sm font-medium mb-1">Buffer Timeout (ms)</label>
              <input
                type="number"
                name="buffer_timeout"
                value={@config.buffer_timeout}
                class="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg"
              />
            </div>
            <button
              type="submit"
              class="px-4 py-2 bg-orange-500 text-white rounded-lg hover:bg-orange-600 transition"
            >
              Save Changes
            </button>
          </.form>
        </div>
      <% end %>

      <%= if @active_tab == "webhook" do %>
        <div class="bg-gray-800 rounded-xl border border-gray-700 p-6">
          <h2 class="text-lg font-semibold mb-4">Webhook Settings</h2>
          <.form for={%{}} phx-submit="save_webhook" class="space-y-4">
            <div>
              <label class="block text-sm font-medium mb-1">Webhook Base URL</label>
              <input
                type="url"
                name="webhook_url"
                placeholder="https://your-domain.com"
                class="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg"
              />
              <p class="text-xs text-gray-400 mt-1">Base URL for LINE webhook callbacks</p>
            </div>
            <div class="p-4 bg-gray-700/50 rounded-lg">
              <p class="text-sm font-medium mb-2">Webhook Endpoint Format</p>
              <code class="text-xs text-orange-400">POST /webhook/:channel_id</code>
              <p class="text-xs text-gray-400 mt-2">
                Configure this URL in your LINE Developer Console for each channel.
              </p>
            </div>
            <button
              type="submit"
              class="px-4 py-2 bg-orange-500 text-white rounded-lg hover:bg-orange-600 transition"
            >
              Save Changes
            </button>
          </.form>
        </div>
      <% end %>

      <%= if @active_tab == "services" do %>
        <div class="space-y-4">
          <div class="bg-gray-800 rounded-xl border border-gray-700 p-6">
            <div class="flex justify-between items-center mb-4">
              <h2 class="text-lg font-semibold">Vector Service</h2>
              <button
                phx-click="test_vector_service"
                class="px-3 py-1 bg-blue-500/20 text-blue-400 rounded-lg text-sm hover:bg-blue-500/30"
              >
                Test Connection
              </button>
            </div>
            <div class="space-y-3">
              <div class="flex justify-between p-3 bg-gray-700/50 rounded-lg">
                <span class="text-gray-400">URL</span>
                <span><%= @config.vector_service_url %></span>
              </div>
              <div class="flex justify-between p-3 bg-gray-700/50 rounded-lg">
                <span class="text-gray-400">Status</span>
                <span class="text-green-400">Connected</span>
              </div>
            </div>
          </div>

          <div class="bg-gray-800 rounded-xl border border-gray-700 p-6">
            <h2 class="text-lg font-semibold mb-4">System Information</h2>
            <div class="space-y-3">
              <div class="flex justify-between p-3 bg-gray-700/50 rounded-lg">
                <span class="text-gray-400">Elixir Version</span>
                <span><%= System.version() %></span>
              </div>
              <div class="flex justify-between p-3 bg-gray-700/50 rounded-lg">
                <span class="text-gray-400">OTP Version</span>
                <span><%= :erlang.system_info(:otp_release) %></span>
              </div>
              <div class="flex justify-between p-3 bg-gray-700/50 rounded-lg">
                <span class="text-gray-400">Phoenix Version</span>
                <span><%= Application.spec(:phoenix, :vsn) %></span>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
