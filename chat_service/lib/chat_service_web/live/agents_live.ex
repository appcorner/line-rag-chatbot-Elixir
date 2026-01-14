defmodule ChatServiceWeb.AgentsLive do
  use ChatServiceWeb, :live_view

  @skills [
    %{id: "web_search", name: "Web Search", description: "Search the web for information", category: "search", icon: "magnifying-glass"},
    %{id: "calculator", name: "Calculator", description: "Perform mathematical calculations", category: "utility", icon: "calculator"},
    %{id: "code_interpreter", name: "Code Interpreter", description: "Execute and analyze code", category: "code", icon: "code"},
    %{id: "file_reader", name: "File Reader", description: "Read and analyze documents", category: "document", icon: "document"},
    %{id: "rag_search", name: "RAG Search", description: "Search through knowledge base", category: "search", icon: "database"},
    %{id: "image_generation", name: "Image Generation", description: "Generate images from text", category: "creative", icon: "photo"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    agents = ChatService.Agents.Supervisor.list_agents()

    {:ok,
     socket
     |> assign(:page_title, "Agents")
     |> assign(:agents, agents)
     |> assign(:skills, @skills)
     |> assign(:show_modal, false)
     |> assign(:selected_skills, [])
     |> assign(:form, to_form(%{"name" => "", "description" => "", "model" => "gpt-4o-mini"}))}
  end

  @impl true
  def handle_event("show_create_modal", _, socket) do
    {:noreply, assign(socket, show_modal: true, selected_skills: [])}
  end

  def handle_event("close_modal", _, socket) do
    {:noreply, assign(socket, :show_modal, false)}
  end

  def handle_event("toggle_skill", %{"skill" => skill_id}, socket) do
    selected = socket.assigns.selected_skills
    new_selected = if skill_id in selected do
      List.delete(selected, skill_id)
    else
      [skill_id | selected]
    end
    {:noreply, assign(socket, :selected_skills, new_selected)}
  end

  def handle_event("create_agent", params, socket) do
    agent_params = %{
      "name" => params["name"],
      "description" => params["description"],
      "model" => params["model"],
      "skills" => socket.assigns.selected_skills
    }

    case ChatService.Agents.Supervisor.start_agent(agent_params) do
      {:ok, _agent_id} ->
        agents = ChatService.Agents.Supervisor.list_agents()
        {:noreply,
         socket
         |> assign(:agents, agents)
         |> assign(:show_modal, false)
         |> put_flash(:info, "Agent created successfully")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create agent: #{inspect(reason)}")}
    end
  end

  def handle_event("delete_agent", %{"id" => agent_id}, socket) do
    ChatService.Agents.Supervisor.stop_agent(agent_id)
    agents = ChatService.Agents.Supervisor.list_agents()
    {:noreply,
     socket
     |> assign(:agents, agents)
     |> put_flash(:info, "Agent deleted")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex justify-between items-center">
        <h1 class="text-2xl font-bold">AI Agents</h1>
        <button
          phx-click="show_create_modal"
          class="px-4 py-2 bg-orange-500 text-white rounded-lg hover:bg-orange-600 transition"
        >
          + Create Agent
        </button>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <div class="bg-gray-800 rounded-xl border border-gray-700 p-6">
          <h2 class="text-lg font-semibold mb-4">Active Agents</h2>
          <div class="space-y-3">
            <%= for agent <- @agents do %>
              <div class="p-4 bg-gray-700/50 rounded-lg">
                <div class="flex justify-between items-start">
                  <div>
                    <h3 class="font-medium"><%= agent.name || agent.id %></h3>
                    <p class="text-sm text-gray-400"><%= agent.description || "No description" %></p>
                  </div>
                  <div class="flex items-center gap-2">
                    <span class="px-2 py-1 bg-green-500/20 text-green-400 text-xs rounded">Active</span>
                    <button
                      phx-click="delete_agent"
                      phx-value-id={agent.id}
                      class="p-1 text-gray-400 hover:text-red-400"
                    >
                      <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/>
                      </svg>
                    </button>
                  </div>
                </div>
                <div class="mt-2 flex flex-wrap gap-1">
                  <%= for skill <- agent.skills || [] do %>
                    <span class="px-2 py-0.5 bg-gray-600 text-xs rounded"><%= skill %></span>
                  <% end %>
                </div>
              </div>
            <% end %>
            <%= if @agents == [] do %>
              <div class="text-center py-8 text-gray-500">
                No active agents. Create one to get started.
              </div>
            <% end %>
          </div>
        </div>

        <div class="bg-gray-800 rounded-xl border border-gray-700 p-6">
          <h2 class="text-lg font-semibold mb-4">Available Skills</h2>
          <div class="grid grid-cols-2 gap-3">
            <%= for skill <- @skills do %>
              <div class="p-3 bg-gray-700/50 rounded-lg">
                <div class="flex items-center gap-2 mb-1">
                  <div class={"w-8 h-8 rounded flex items-center justify-center #{category_color(skill.category)}"}>
                    <%= skill_icon(skill.icon) %>
                  </div>
                  <span class="font-medium text-sm"><%= skill.name %></span>
                </div>
                <p class="text-xs text-gray-400"><%= skill.description %></p>
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <%= if @show_modal do %>
        <div class="fixed inset-0 bg-black/50 flex items-center justify-center z-50">
          <div class="bg-gray-800 rounded-xl border border-gray-700 p-6 w-full max-w-lg" phx-click-away="close_modal">
            <h2 class="text-xl font-bold mb-4">Create Agent</h2>
            <.form for={@form} phx-submit="create_agent" class="space-y-4">
              <div>
                <label class="block text-sm font-medium mb-1">Name</label>
                <input
                  type="text"
                  name="name"
                  required
                  class="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg"
                  placeholder="My Assistant"
                />
              </div>
              <div>
                <label class="block text-sm font-medium mb-1">Description</label>
                <textarea
                  name="description"
                  rows="2"
                  class="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg"
                  placeholder="What does this agent do?"
                ></textarea>
              </div>
              <div>
                <label class="block text-sm font-medium mb-1">Model</label>
                <select name="model" class="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded-lg">
                  <option value="gpt-4o-mini">GPT-4o Mini</option>
                  <option value="gpt-4o">GPT-4o</option>
                  <option value="claude-3-5-sonnet-20241022">Claude 3.5 Sonnet</option>
                  <option value="gemini-1.5-flash">Gemini 1.5 Flash</option>
                </select>
              </div>
              <div>
                <label class="block text-sm font-medium mb-2">Skills</label>
                <div class="grid grid-cols-2 gap-2">
                  <%= for skill <- @skills do %>
                    <button
                      type="button"
                      phx-click="toggle_skill"
                      phx-value-skill={skill.id}
                      class={"p-2 rounded-lg border text-left text-sm transition #{if skill.id in @selected_skills, do: "border-orange-500 bg-orange-500/10", else: "border-gray-600 hover:border-gray-500"}"}
                    >
                      <%= skill.name %>
                    </button>
                  <% end %>
                </div>
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
                  Create
                </button>
              </div>
            </.form>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp category_color("search"), do: "bg-blue-500/20 text-blue-400"
  defp category_color("utility"), do: "bg-green-500/20 text-green-400"
  defp category_color("code"), do: "bg-purple-500/20 text-purple-400"
  defp category_color("document"), do: "bg-yellow-500/20 text-yellow-400"
  defp category_color("creative"), do: "bg-pink-500/20 text-pink-400"
  defp category_color(_), do: "bg-gray-500/20 text-gray-400"

  defp skill_icon(_) do
    Phoenix.HTML.raw("""
    <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z"/>
    </svg>
    """)
  end
end
