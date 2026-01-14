defmodule ChatServiceWeb.LlmTestLive do
  use ChatServiceWeb, :live_view

  alias ChatService.Repo
  alias ChatService.Schemas.Channel
  alias ChatService.Services.Ai.Service, as: AiService
  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "LLM Test")
     |> assign(:channels, list_channels())
     |> assign(:selected_channel, nil)
     |> assign(:messages, [])
     |> assign(:input, "")
     |> assign(:loading, false)
     |> assign(:start_time, nil)
     |> assign(:show_history, false)
     |> assign(:last_request_info, nil)}
  end

  defp list_channels do
    Channel
    |> where([c], c.is_active == true)
    |> order_by([c], asc: c.name)
    |> Repo.all()
  end

  @impl true
  def handle_event("select_channel", %{"id" => id}, socket) do
    channel = Enum.find(socket.assigns.channels, fn c -> to_string(c.id) == id end)
    {:noreply,
     socket
     |> assign(:selected_channel, channel)
     |> assign(:messages, [])
     |> assign(:last_request_info, nil)}
  end

  def handle_event("update_input", %{"value" => value}, socket) do
    {:noreply, assign(socket, :input, value)}
  end

  def handle_event("toggle_history", _, socket) do
    {:noreply, assign(socket, :show_history, !socket.assigns.show_history)}
  end

  def handle_event("send_message", %{"message" => message}, socket) when message != "" do
    channel = socket.assigns.selected_channel

    if channel do
      # Add user message to chat
      user_msg = %{role: "user", content: message, timestamp: DateTime.utc_now()}
      messages = socket.assigns.messages ++ [user_msg]

      # Record start time for response time measurement
      start_time = System.monotonic_time(:millisecond)

      socket =
        socket
        |> assign(:messages, messages)
        |> assign(:input, "")
        |> assign(:loading, true)
        |> assign(:start_time, start_time)

      # Process async with current messages as history
      send(self(), {:process_message, channel, message, messages})

      {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, "Please select a LINE OA channel first")}
    end
  end

  def handle_event("send_message", _, socket) do
    {:noreply, socket}
  end

  def handle_event("clear_chat", _, socket) do
    {:noreply,
     socket
     |> assign(:messages, [])
     |> assign(:last_request_info, nil)}
  end

  @impl true
  def handle_info({:process_message, channel, message, current_messages}, socket) do
    # Build history from current messages (excluding the last user message we just added)
    history = build_history_from_messages(Enum.drop(current_messages, -1))

    # Call AI service with custom history
    result = AiService.process_message_with_details(channel, "test_user", message, history)

    # Calculate response time
    end_time = System.monotonic_time(:millisecond)
    start_time = socket.assigns.start_time || end_time
    response_time_ms = end_time - start_time

    socket =
      case result do
        {:ok, %{status: :ai_disabled}} ->
          assistant_msg = %{
            role: "system",
            content: "AI is disabled for this channel",
            timestamp: DateTime.utc_now(),
            response_time: response_time_ms
          }
          socket
          |> assign(:messages, socket.assigns.messages ++ [assistant_msg])
          |> assign(:last_request_info, %{status: :ai_disabled, history: history})

        {:ok, %{message: response, history: sent_history, request: request_info}} ->
          assistant_msg = %{
            role: "assistant",
            content: response,
            timestamp: DateTime.utc_now(),
            response_time: response_time_ms
          }
          socket
          |> assign(:messages, socket.assigns.messages ++ [assistant_msg])
          |> assign(:last_request_info, %{
            status: :success,
            history: sent_history,
            request: request_info,
            response_time: response_time_ms
          })

        {:error, reason} ->
          error_msg = %{
            role: "error",
            content: "Error: #{inspect(reason)}",
            timestamp: DateTime.utc_now(),
            response_time: response_time_ms
          }
          socket
          |> assign(:messages, socket.assigns.messages ++ [error_msg])
          |> assign(:last_request_info, %{status: :error, error: reason, history: history})
      end

    {:noreply,
     socket
     |> assign(:loading, false)
     |> assign(:start_time, nil)}
  end

  defp build_history_from_messages(messages) do
    messages
    |> Enum.filter(fn msg -> msg.role in ["user", "assistant"] end)
    |> Enum.map(fn msg ->
      %{role: msg.role, content: msg.content}
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex justify-between items-center">
        <h1 class="text-2xl font-bold">LLM Test</h1>
        <div class="flex items-center gap-4">
          <button
            phx-click="toggle_history"
            class={"px-3 py-1 rounded-lg text-sm transition #{if @show_history, do: "bg-orange-500 text-white", else: "bg-gray-700 text-gray-300 hover:bg-gray-600"}"}
          >
            <svg class="w-4 h-4 inline mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"/>
            </svg>
            History Log
          </button>
          <div class="text-sm text-gray-400">
            Test your LINE OA's AI response
          </div>
        </div>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-4 gap-6">
        <!-- Channel Selection -->
        <div class="lg:col-span-1">
          <div class="bg-gray-800 rounded-xl border border-gray-700 p-4">
            <h2 class="text-lg font-semibold mb-4">Select LINE OA</h2>
            <div class="space-y-2">
              <%= for channel <- @channels do %>
                <button
                  phx-click="select_channel"
                  phx-value-id={channel.id}
                  class={"w-full text-left p-3 rounded-lg border transition #{if @selected_channel && @selected_channel.id == channel.id, do: "border-orange-500 bg-orange-500/10", else: "border-gray-700 hover:border-gray-600"}"}
                >
                  <div class="font-medium"><%= channel.name || channel.channel_id %></div>
                  <div class="text-xs text-gray-400 mt-1">
                    <%= get_provider_label(channel) %>
                  </div>
                </button>
              <% end %>

              <%= if @channels == [] do %>
                <div class="text-gray-500 text-sm text-center py-4">
                  No channels configured
                </div>
              <% end %>
            </div>
          </div>

          <%= if @selected_channel do %>
            <div class="bg-gray-800 rounded-xl border border-gray-700 p-4 mt-4">
              <h3 class="text-sm font-medium text-gray-400 mb-3">Channel Info</h3>
              <dl class="space-y-2 text-sm">
                <div>
                  <dt class="text-gray-500">Provider</dt>
                  <dd class="font-medium"><%= get_setting(@selected_channel, "llm_provider", "openai") %></dd>
                </div>
                <div>
                  <dt class="text-gray-500">Model</dt>
                  <dd class="font-medium"><%= get_setting(@selected_channel, "llm_model", "gpt-4o-mini") %></dd>
                </div>
                <div>
                  <dt class="text-gray-500">AI Status</dt>
                  <dd>
                    <%= if get_setting(@selected_channel, "ai_enabled", true) do %>
                      <span class="text-green-400">Enabled</span>
                    <% else %>
                      <span class="text-red-400">Disabled</span>
                    <% end %>
                  </dd>
                </div>
                <div>
                  <dt class="text-gray-500">Dataset</dt>
                  <dd class="font-medium"><%= get_setting(@selected_channel, "dataset_id", "-") || "-" %></dd>
                </div>
              </dl>
            </div>
          <% end %>
        </div>

        <!-- Chat Area -->
        <div class={if @show_history, do: "lg:col-span-2", else: "lg:col-span-3"}>
          <div class="bg-gray-800 rounded-xl border border-gray-700 h-[600px] flex flex-col">
            <!-- Chat Header -->
            <div class="p-4 border-b border-gray-700 flex justify-between items-center">
              <div>
                <h2 class="font-semibold">
                  <%= if @selected_channel, do: @selected_channel.name || @selected_channel.channel_id, else: "Select a channel" %>
                </h2>
                <p class="text-xs text-gray-400">
                  Test conversation
                  <%= if length(@messages) > 0 do %>
                    (<%= div(length(@messages), 2) %> exchanges)
                  <% end %>
                </p>
              </div>
              <%= if @messages != [] do %>
                <button
                  phx-click="clear_chat"
                  class="text-sm text-gray-400 hover:text-white transition"
                >
                  Clear Chat
                </button>
              <% end %>
            </div>

            <!-- Messages -->
            <div class="flex-1 overflow-y-auto p-4 space-y-4" id="chat-messages">
              <%= if @messages == [] do %>
                <div class="flex items-center justify-center h-full text-gray-500">
                  <%= if @selected_channel do %>
                    Start typing to test the AI response
                  <% else %>
                    Please select a LINE OA channel first
                  <% end %>
                </div>
              <% else %>
                <%= for {msg, idx} <- Enum.with_index(@messages) do %>
                  <div class={"flex #{if msg.role == "user", do: "justify-end", else: "justify-start"}"} id={"msg-#{idx}"}>
                    <div class={message_class(msg.role)}>
                      <%= if msg.role == "error" do %>
                        <div class="flex items-center gap-2">
                          <svg class="w-4 h-4 text-red-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/>
                          </svg>
                          <span><%= msg.content %></span>
                        </div>
                      <% else %>
                        <p class="whitespace-pre-wrap"><%= msg.content %></p>
                      <% end %>
                      <div class="text-xs opacity-50 mt-1 flex items-center gap-2">
                        <span><%= format_time(msg.timestamp) %></span>
                        <%= if msg[:response_time] do %>
                          <span class="text-orange-400">
                            <svg class="w-3 h-3 inline" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"/>
                            </svg>
                            <%= format_response_time(msg.response_time) %>
                          </span>
                        <% end %>
                      </div>
                    </div>
                  </div>
                <% end %>
              <% end %>

              <%= if @loading do %>
                <div class="flex justify-start">
                  <div class="bg-gray-700 rounded-lg px-4 py-2">
                    <div class="flex items-center gap-2">
                      <div class="w-2 h-2 bg-orange-500 rounded-full animate-bounce"></div>
                      <div class="w-2 h-2 bg-orange-500 rounded-full animate-bounce" style="animation-delay: 0.1s"></div>
                      <div class="w-2 h-2 bg-orange-500 rounded-full animate-bounce" style="animation-delay: 0.2s"></div>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>

            <!-- Input -->
            <div class="p-4 border-t border-gray-700">
              <form phx-submit="send_message" class="flex gap-2">
                <input
                  type="text"
                  name="message"
                  value={@input}
                  phx-keyup="update_input"
                  placeholder={if @selected_channel, do: "Type a message...", else: "Select a channel first"}
                  disabled={is_nil(@selected_channel) || @loading}
                  class="flex-1 px-4 py-2 bg-gray-700 border border-gray-600 rounded-lg focus:outline-none focus:border-orange-500 disabled:opacity-50 disabled:cursor-not-allowed"
                  autocomplete="off"
                />
                <button
                  type="submit"
                  disabled={is_nil(@selected_channel) || @loading || @input == ""}
                  class="px-6 py-2 bg-orange-500 text-white rounded-lg hover:bg-orange-600 transition disabled:opacity-50 disabled:cursor-not-allowed"
                >
                  <%= if @loading do %>
                    <svg class="w-5 h-5 animate-spin" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"/>
                    </svg>
                  <% else %>
                    Send
                  <% end %>
                </button>
              </form>
            </div>
          </div>
        </div>

        <!-- History Log Panel -->
        <%= if @show_history do %>
          <div class="lg:col-span-1">
            <div class="bg-gray-800 rounded-xl border border-gray-700 h-[600px] flex flex-col">
              <div class="p-4 border-b border-gray-700">
                <h2 class="font-semibold flex items-center gap-2">
                  <svg class="w-5 h-5 text-orange-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"/>
                  </svg>
                  History Log
                </h2>
                <p class="text-xs text-gray-400">Context sent to AI</p>
              </div>

              <div class="flex-1 overflow-y-auto p-4">
                <%= if @last_request_info do %>
                  <!-- Request Info -->
                  <%= if @last_request_info[:request] do %>
                    <div class="mb-4">
                      <h3 class="text-xs font-medium text-gray-400 uppercase mb-2">Request Info</h3>
                      <div class="bg-gray-700/50 rounded-lg p-3 text-xs space-y-1">
                        <div class="flex justify-between">
                          <span class="text-gray-400">Provider:</span>
                          <span class="text-white"><%= @last_request_info.request.provider %></span>
                        </div>
                        <div class="flex justify-between">
                          <span class="text-gray-400">Model:</span>
                          <span class="text-white"><%= @last_request_info.request.model %></span>
                        </div>
                        <div class="flex justify-between">
                          <span class="text-gray-400">Mode:</span>
                          <span class={if @last_request_info.request[:agent_mode], do: "text-blue-400", else: "text-cyan-400"}>
                            <%= if @last_request_info.request[:agent_mode], do: "Agent", else: "Normal" %>
                          </span>
                        </div>
                        <div class="flex justify-between">
                          <span class="text-gray-400">Skills:</span>
                          <span class="text-purple-400"><%= length(@last_request_info.request.skills) %></span>
                        </div>
                        <div class="flex justify-between">
                          <span class="text-gray-400">History Count:</span>
                          <span class="text-orange-400"><%= @last_request_info.request.history_count %></span>
                        </div>
                        <%= if @last_request_info[:response_time] do %>
                          <div class="flex justify-between">
                            <span class="text-gray-400">Response Time:</span>
                            <span class="text-green-400"><%= format_response_time(@last_request_info.response_time) %></span>
                          </div>
                        <% end %>
                      </div>
                    </div>
                  <% end %>

                  <!-- History Sent -->
                  <div>
                    <h3 class="text-xs font-medium text-gray-400 uppercase mb-2">
                      Conversation History Sent
                      <span class="text-orange-400">(<%= length(@last_request_info.history) %> messages)</span>
                    </h3>

                    <%= if @last_request_info.history == [] do %>
                      <div class="text-gray-500 text-sm text-center py-4">
                        No history (first message)
                      </div>
                    <% else %>
                      <div class="space-y-2">
                        <%= for {hist_msg, idx} <- Enum.with_index(@last_request_info.history) do %>
                          <div class={"p-2 rounded text-xs #{if hist_msg.role == "user", do: "bg-orange-500/20 border-l-2 border-orange-500", else: "bg-gray-700/50 border-l-2 border-gray-500"}"} id={"hist-#{idx}"}>
                            <div class="font-medium text-gray-400 mb-1">
                              <%= if hist_msg.role == "user", do: "User", else: "Assistant" %>
                            </div>
                            <div class="text-white line-clamp-3">
                              <%= hist_msg.content %>
                            </div>
                          </div>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                <% else %>
                  <div class="flex items-center justify-center h-full text-gray-500 text-sm">
                    Send a message to see the history log
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp message_class("user"), do: "bg-orange-500 text-white rounded-lg px-4 py-2 max-w-[80%]"
  defp message_class("assistant"), do: "bg-gray-700 text-white rounded-lg px-4 py-2 max-w-[80%]"
  defp message_class("system"), do: "bg-yellow-500/20 text-yellow-400 rounded-lg px-4 py-2 max-w-[80%]"
  defp message_class("error"), do: "bg-red-500/20 text-red-400 rounded-lg px-4 py-2 max-w-[80%]"
  defp message_class(_), do: "bg-gray-700 text-white rounded-lg px-4 py-2 max-w-[80%]"

  defp get_provider_label(channel) do
    settings = channel.settings || %{}
    provider = settings["llm_provider"] || "openai"
    model = settings["llm_model"] || "gpt-4o-mini"
    "#{provider} / #{model}"
  end

  defp get_setting(channel, key, default) do
    settings = channel.settings || %{}
    settings[key] || default
  end

  defp format_time(datetime) do
    Calendar.strftime(datetime, "%H:%M")
  end

  defp format_response_time(ms) when ms < 1000 do
    "#{ms}ms"
  end

  defp format_response_time(ms) do
    seconds = ms / 1000
    "#{:erlang.float_to_binary(seconds, decimals: 2)}s"
  end
end
