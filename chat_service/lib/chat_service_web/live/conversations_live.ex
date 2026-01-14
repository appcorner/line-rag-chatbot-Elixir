defmodule ChatServiceWeb.ConversationsLive do
  use ChatServiceWeb, :live_view

  alias ChatService.Repo
  alias ChatService.Schemas.{Message, Channel, User}
  alias ChatService.Services.Line.Api, as: LineApi
  alias ChatService.AdminPresence
  import Ecto.Query

  @typing_timeout 3000

  @impl true
  def mount(_params, session, socket) do
    # Generate unique admin ID for this session
    admin_id = session["admin_id"] || generate_admin_id()
    admin_name = session["admin_name"] || "Admin #{String.slice(admin_id, 0, 4)}"

    if connected?(socket) do
      # Subscribe to global channels
      Phoenix.PubSub.subscribe(ChatService.PubSub, "webhooks")
      Phoenix.PubSub.subscribe(ChatService.PubSub, "messages")
      Phoenix.PubSub.subscribe(ChatService.PubSub, "users")
      Phoenix.PubSub.subscribe(ChatService.PubSub, "admin:messages")

      # Track admin on conversations page
      AdminPresence.track_admin(
        self(),
        AdminPresence.conversations_page_topic(),
        admin_id,
        %{name: admin_name}
      )

      # Subscribe to presence updates
      Phoenix.PubSub.subscribe(ChatService.PubSub, AdminPresence.conversations_page_topic())
    end

    users_with_unread = list_users_with_unread()

    {:ok,
     socket
     |> assign(:page_title, "Conversations")
     |> assign(:admin_id, admin_id)
     |> assign(:admin_name, admin_name)
     |> assign(:admin_color, AdminPresence.generate_color(admin_id))
     |> assign(:webhook_logs, [])
     |> assign(:users, users_with_unread)
     |> assign(:selected_user, nil)
     |> assign(:chat_messages, [])
     |> assign(:selected_channel, nil)
     |> assign(:channels, list_channels())
     |> assign(:view_mode, "chats")
     |> assign(:editing_user, nil)
     |> assign(:user_form, %{})
     |> assign(:reply_text, "")
     |> assign(:sending, false)
     |> assign(:online_admins, [])
     |> assign(:viewing_admins, [])
     |> assign(:typing_admins, [])
     |> assign(:current_topic, nil)
     |> assign(:typing_timer, nil)
     |> assign(:pending_images, [])
     |> assign(:image_modal, nil)
     |> assign(:send_error, nil)
     |> assign(:image_url_input, "")
     |> assign(:show_delete_confirm, false)}
  end

  defp generate_admin_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  # Handle presence updates
  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", payload: _diff}, socket) do
    # Update online admins list
    online_admins = AdminPresence.list_admins(AdminPresence.conversations_page_topic())

    # Update viewing admins for current conversation
    viewing_admins = if socket.assigns.current_topic do
      AdminPresence.list_admins(socket.assigns.current_topic)
      |> Enum.reject(fn admin -> admin.admin_id == socket.assigns.admin_id end)
    else
      []
    end

    # Update typing admins
    typing_admins = if socket.assigns.current_topic do
      AdminPresence.list_typing(socket.assigns.current_topic)
      |> Enum.reject(fn admin -> admin.admin_id == socket.assigns.admin_id end)
    else
      []
    end

    {:noreply,
     socket
     |> assign(:online_admins, online_admins)
     |> assign(:viewing_admins, viewing_admins)
     |> assign(:typing_admins, typing_admins)}
  end

  # Handle admin message broadcast (from other admins)
  def handle_info({:admin_message_sent, %{admin_id: sender_id, message: message, user_id: user_id}}, socket) do
    # Only update if viewing the same user and not the sender
    if socket.assigns.selected_user &&
       socket.assigns.selected_user.line_user_id == user_id &&
       sender_id != socket.assigns.admin_id do
      chat_messages = socket.assigns.chat_messages ++ [message]
      {:noreply, assign(socket, :chat_messages, chat_messages)}
    else
      {:noreply, socket}
    end
  end

  # Handle typing status broadcast
  def handle_info({:admin_typing, %{admin_id: sender_id, topic: topic, typing: typing}}, socket) do
    if topic == socket.assigns.current_topic && sender_id != socket.assigns.admin_id do
      typing_admins = if typing do
        admin_meta = %{admin_id: sender_id, name: "Admin #{String.slice(sender_id, 0, 4)}"}
        [admin_meta | socket.assigns.typing_admins]
        |> Enum.uniq_by(& &1.admin_id)
      else
        Enum.reject(socket.assigns.typing_admins, & &1.admin_id == sender_id)
      end
      {:noreply, assign(socket, :typing_admins, typing_admins)}
    else
      {:noreply, socket}
    end
  end

  # Clear typing indicator after timeout
  def handle_info(:clear_typing, socket) do
    if socket.assigns.current_topic do
      AdminPresence.update_typing(self(), socket.assigns.current_topic, socket.assigns.admin_id, false)
      broadcast_typing(socket, false)
    end
    {:noreply, assign(socket, :typing_timer, nil)}
  end

  def handle_info({:webhook_received, data}, socket) do
    log_entry = %{
      id: System.unique_integer([:positive]),
      timestamp: DateTime.utc_now(),
      channel_id: data[:channel_id],
      event_type: data[:event_type],
      user_id: data[:user_id],
      message_type: data[:message_type],
      message_text: data[:message_text],
      raw: data[:raw],
      processed: false
    }

    webhook_logs = [log_entry | socket.assigns.webhook_logs] |> Enum.take(50)
    {:noreply, assign(socket, :webhook_logs, webhook_logs)}
  end

  def handle_info({:message_saved, message}, socket) do
    users = list_users_with_unread()
    socket = assign(socket, :users, users)

    if socket.assigns.selected_user &&
       socket.assigns.selected_user.line_user_id == message.user_id do
      chat_messages = socket.assigns.chat_messages ++ [message]
      mark_messages_as_read(message.user_id, message.channel_id)
      {:noreply, assign(socket, :chat_messages, chat_messages)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:user_updated, _data}, socket) do
    users = list_users_with_unread()
    {:noreply, assign(socket, :users, users)}
  end

  def handle_info({:do_send_images, user, channel, images}, socket) do
    require Logger
    Logger.info("[Admin #{socket.assigns.admin_id}] Sending #{length(images)} images to #{user.line_user_id}")

    # Get base URL for constructing absolute URLs (LINE API requires full URLs)
    base_url = Application.get_env(:chat_service, :public_url)

    # Check if we have a public URL configured
    if is_nil(base_url) || String.contains?(base_url || "", "localhost") do
      Logger.error("Cannot send images: public_url not configured. LINE requires HTTPS public URLs.")
      {:noreply,
       socket
       |> assign(:sending, false)
       |> assign(:send_error, "Cannot send images: Server requires public URL (HTTPS). Use ngrok or configure :public_url")}
    else
      # Save images to uploads folder and get public URLs
      uploaded_paths = Enum.map(images, fn img ->
        save_image_from_base64(img.preview, img.filename)
      end)
      |> Enum.filter(&(&1 != nil))

      # Convert relative paths to absolute URLs for LINE API
      uploaded_urls = Enum.map(uploaded_paths, fn path -> "#{base_url}#{path}" end)

      if uploaded_urls != [] do
        # Send images via LINE API (requires absolute URLs)
        case LineApi.push_images(user.line_user_id, uploaded_urls, channel.access_token) do
          :ok ->
            Logger.info("Images sent successfully")

            # Save messages to database
            new_messages = Enum.map(uploaded_urls, fn url ->
              attrs = %{
                user_id: user.line_user_id,
                channel_id: user.channel_id,
                content: url,
                message_type: "image",
                direction: :outgoing,
                role: "assistant",
                is_read: true,
                metadata: %{
                  image_url: url,
                  sent_by: socket.assigns.admin_id,
                  admin_name: socket.assigns.admin_name
                }
              }

              case %Message{} |> Message.changeset(attrs) |> Repo.insert() do
                {:ok, msg} -> msg
                _ -> nil
              end
            end)
            |> Enum.filter(&(&1 != nil))

            chat_messages = socket.assigns.chat_messages ++ new_messages
            users = list_users_with_unread(socket.assigns.selected_channel)

            # Broadcast to other admins
            Enum.each(new_messages, fn msg ->
              Phoenix.PubSub.broadcast(
                ChatService.PubSub,
                "admin:messages",
                {:admin_message_sent, %{
                  admin_id: socket.assigns.admin_id,
                  message: msg,
                  user_id: user.line_user_id
                }}
              )
            end)

            {:noreply,
             socket
             |> assign(:chat_messages, chat_messages)
             |> assign(:users, users)
             |> assign(:pending_images, [])
             |> assign(:sending, false)
             |> assign(:send_error, nil)}

          {:error, reason} ->
            Logger.error("Failed to send images: #{inspect(reason)}")
            {:noreply,
             socket
             |> assign(:sending, false)
             |> assign(:send_error, "Failed to send images to LINE")}
        end
      else
        {:noreply,
         socket
         |> assign(:sending, false)
         |> assign(:send_error, "Failed to process images")}
      end
    end
  end

  def handle_info({:do_send_image_url, user, channel, url}, socket) do
    require Logger
    Logger.info("[Admin #{socket.assigns.admin_id}] Sending image URL to #{user.line_user_id}: #{url}")

    case LineApi.push_image(user.line_user_id, url, channel.access_token) do
      :ok ->
        Logger.info("Image URL sent successfully")

        attrs = %{
          user_id: user.line_user_id,
          channel_id: user.channel_id,
          content: url,
          message_type: "image",
          direction: :outgoing,
          role: "assistant",
          is_read: true,
          metadata: %{
            image_url: url,
            sent_by: socket.assigns.admin_id,
            admin_name: socket.assigns.admin_name
          }
        }

        case %Message{} |> Message.changeset(attrs) |> Repo.insert() do
          {:ok, saved_msg} ->
            chat_messages = socket.assigns.chat_messages ++ [saved_msg]
            users = list_users_with_unread(socket.assigns.selected_channel)

            # Broadcast to other admins
            Phoenix.PubSub.broadcast(
              ChatService.PubSub,
              "admin:messages",
              {:admin_message_sent, %{
                admin_id: socket.assigns.admin_id,
                message: saved_msg,
                user_id: user.line_user_id
              }}
            )

            {:noreply,
             socket
             |> assign(:chat_messages, chat_messages)
             |> assign(:users, users)
             |> assign(:image_url_input, "")
             |> assign(:sending, false)
             |> assign(:send_error, nil)}

          {:error, changeset} ->
            Logger.error("Failed to save image message: #{inspect(changeset.errors)}")
            {:noreply,
             socket
             |> assign(:sending, false)
             |> assign(:send_error, "Image sent but failed to save")}
        end

      {:error, reason} ->
        Logger.error("Failed to send image URL: #{inspect(reason)}")
        {:noreply,
         socket
         |> assign(:sending, false)
         |> assign(:send_error, "Failed to send image. Ensure URL is publicly accessible HTTPS.")}
    end
  end

  def handle_info({:do_send_message, user, channel, message}, socket) do
    require Logger
    Logger.info("[Admin #{socket.assigns.admin_id}] Sending message to #{user.line_user_id}: #{message}")

    case LineApi.push_message(user.line_user_id, message, channel.access_token) do
      :ok ->
        Logger.info("Message sent successfully")
        attrs = %{
          user_id: user.line_user_id,
          channel_id: user.channel_id,
          content: message,
          direction: :outgoing,
          role: "assistant",
          is_read: true,
          metadata: %{sent_by: socket.assigns.admin_id, admin_name: socket.assigns.admin_name}
        }

        case %Message{} |> Message.changeset(attrs) |> Repo.insert() do
          {:ok, saved_msg} ->
            chat_messages = socket.assigns.chat_messages ++ [saved_msg]
            users = list_users_with_unread(socket.assigns.selected_channel)

            # Broadcast to other admins viewing this conversation
            Phoenix.PubSub.broadcast(
              ChatService.PubSub,
              "admin:messages",
              {:admin_message_sent, %{
                admin_id: socket.assigns.admin_id,
                message: saved_msg,
                user_id: user.line_user_id
              }}
            )

            {:noreply,
             socket
             |> assign(:chat_messages, chat_messages)
             |> assign(:users, users)
             |> assign(:reply_text, "")
             |> assign(:sending, false)}

          {:error, changeset} ->
            Logger.error("Failed to save message: #{inspect(changeset.errors)}")
            {:noreply, assign(socket, :sending, false)}
        end

      {:error, reason} ->
        Logger.error("Failed to send LINE message: #{inspect(reason)}")
        {:noreply, assign(socket, :sending, false)}
    end
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("change_view", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :view_mode, mode)}
  end

  def handle_event("clear_logs", _, socket) do
    {:noreply, assign(socket, :webhook_logs, [])}
  end

  def handle_event("filter_channel", %{"channel" => channel_id}, socket) do
    selected = if channel_id == "", do: nil, else: channel_id
    users = list_users_with_unread(selected)
    {:noreply,
     socket
     |> assign(:selected_channel, selected)
     |> assign(:users, users)
     |> assign(:selected_user, nil)
     |> assign(:chat_messages, [])
     |> leave_conversation()}
  end

  def handle_event("select_user", %{"user-id" => user_id}, socket) do
    user = Enum.find(socket.assigns.users, fn u -> u.line_user_id == user_id end)

    if user do
      # Leave previous conversation if any
      socket = leave_conversation(socket)

      # Join new conversation
      topic = AdminPresence.conversation_topic(user.line_user_id, user.channel_id)

      if connected?(socket) do
        # Subscribe to this conversation's presence
        Phoenix.PubSub.subscribe(ChatService.PubSub, topic)

        # Track admin in this conversation
        AdminPresence.track_admin(
          self(),
          topic,
          socket.assigns.admin_id,
          %{name: socket.assigns.admin_name}
        )
      end

      messages = load_user_messages(user.line_user_id, user.channel_id)
      mark_messages_as_read(user.line_user_id, user.channel_id)
      users = list_users_with_unread(socket.assigns.selected_channel)

      # Get other admins viewing this conversation
      viewing_admins = AdminPresence.list_admins(topic)
        |> Enum.reject(fn admin -> admin.admin_id == socket.assigns.admin_id end)

      {:noreply,
       socket
       |> assign(:selected_user, user)
       |> assign(:chat_messages, messages)
       |> assign(:users, users)
       |> assign(:current_topic, topic)
       |> assign(:viewing_admins, viewing_admins)
       |> assign(:typing_admins, [])}
    else
      {:noreply, socket}
    end
  end

  def handle_event("edit_user", %{"user-id" => user_id}, socket) do
    user = Enum.find(socket.assigns.users, fn u -> u.line_user_id == user_id end)
    {:noreply,
     socket
     |> assign(:editing_user, user)
     |> assign(:user_form, %{
       "tags" => Enum.join(user.tags || [], ", "),
       "notes" => user.notes || ""
     })}
  end

  def handle_event("close_edit", _, socket) do
    {:noreply, assign(socket, :editing_user, nil)}
  end

  def handle_event("save_user", %{"tags" => tags, "notes" => notes}, socket) do
    user = socket.assigns.editing_user

    if user do
      tags_list = tags
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.filter(&(&1 != ""))

      User
      |> where([u], u.id == ^user.id)
      |> Repo.one()
      |> User.changeset(%{tags: tags_list, notes: notes})
      |> Repo.update()

      users = list_users_with_unread(socket.assigns.selected_channel)
      {:noreply,
       socket
       |> assign(:users, users)
       |> assign(:editing_user, nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("mark_all_read", _, socket) do
    if socket.assigns.selected_user do
      user = socket.assigns.selected_user
      mark_messages_as_read(user.line_user_id, user.channel_id)
      users = list_users_with_unread(socket.assigns.selected_channel)
      {:noreply, assign(socket, :users, users)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_reply", %{"message" => text}, socket) do
    # Update typing indicator
    socket = if socket.assigns.current_topic && text != "" do
      # Cancel previous timer
      if socket.assigns.typing_timer do
        Process.cancel_timer(socket.assigns.typing_timer)
      end

      # Set typing to true
      AdminPresence.update_typing(self(), socket.assigns.current_topic, socket.assigns.admin_id, true)
      broadcast_typing(socket, true)

      # Set timer to clear typing
      timer = Process.send_after(self(), :clear_typing, @typing_timeout)
      assign(socket, :typing_timer, timer)
    else
      if socket.assigns.current_topic do
        AdminPresence.update_typing(self(), socket.assigns.current_topic, socket.assigns.admin_id, false)
        broadcast_typing(socket, false)
      end
      socket
    end

    {:noreply, assign(socket, :reply_text, text)}
  end

  def handle_event("send_message", %{"message" => message}, socket) when message != "" do
    user = socket.assigns.selected_user

    if user do
      # Clear typing indicator
      if socket.assigns.current_topic do
        AdminPresence.update_typing(self(), socket.assigns.current_topic, socket.assigns.admin_id, false)
        broadcast_typing(socket, false)
      end

      socket = assign(socket, :sending, true)
      channel = get_channel_by_id(user.channel_id)

      if channel do
        send(self(), {:do_send_message, user, channel, message})
        {:noreply, socket}
      else
        {:noreply, assign(socket, :sending, false)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("send_message", _, socket), do: {:noreply, socket}

  # Image handling events
  def handle_event("add_images", %{"images" => images}, socket) do
    # Images come from JS hook as base64 data URLs
    pending = socket.assigns.pending_images ++ Enum.map(images, fn img ->
      %{preview: img["data"], filename: img["name"], size: img["size"]}
    end)
    {:noreply, assign(socket, :pending_images, Enum.take(pending, 10))}
  end

  def handle_event("remove_image", %{"index" => index}, socket) do
    index = String.to_integer(index)
    pending = List.delete_at(socket.assigns.pending_images, index)
    {:noreply, assign(socket, :pending_images, pending)}
  end

  def handle_event("clear_images", _, socket) do
    {:noreply, assign(socket, :pending_images, [])}
  end

  def handle_event("view_image", %{"url" => url}, socket) do
    {:noreply, assign(socket, :image_modal, url)}
  end

  def handle_event("close_image_modal", _, socket) do
    {:noreply, assign(socket, :image_modal, nil)}
  end

  def handle_event("send_images", _, socket) do
    user = socket.assigns.selected_user
    images = socket.assigns.pending_images

    if user && images != [] do
      socket = assign(socket, :sending, true)
      channel = get_channel_by_id(user.channel_id)

      if channel do
        send(self(), {:do_send_images, user, channel, images})
        {:noreply, socket}
      else
        {:noreply, assign(socket, :sending, false)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_image_url", %{"url" => url}, socket) do
    {:noreply, assign(socket, :image_url_input, url)}
  end

  def handle_event("send_image_url", %{"url" => url}, socket) when url != "" do
    user = socket.assigns.selected_user

    if user && String.starts_with?(url, "http") do
      socket = assign(socket, :sending, true)
      channel = get_channel_by_id(user.channel_id)

      if channel do
        send(self(), {:do_send_image_url, user, channel, url})
        {:noreply, socket}
      else
        {:noreply, assign(socket, :sending, false)}
      end
    else
      {:noreply, assign(socket, :send_error, "Please enter a valid image URL (https://...)")}
    end
  end

  def handle_event("send_image_url", _, socket), do: {:noreply, socket}

  def handle_event("clear_error", _, socket) do
    {:noreply, assign(socket, :send_error, nil)}
  end

  def handle_event("confirm_delete_chat", _, socket) do
    {:noreply, assign(socket, :show_delete_confirm, true)}
  end

  def handle_event("cancel_delete", _, socket) do
    {:noreply, assign(socket, :show_delete_confirm, false)}
  end

  def handle_event("delete_chat", _, socket) do
    user = socket.assigns.selected_user

    if user do
      # Delete all messages for this user in this channel
      Message
      |> where([m], m.user_id == ^user.line_user_id and m.channel_id == ^user.channel_id)
      |> Repo.delete_all()

      # Leave conversation and refresh
      socket = leave_conversation(socket)
      users = list_users_with_unread(socket.assigns.selected_channel)

      {:noreply,
       socket
       |> assign(:users, users)
       |> assign(:selected_user, nil)
       |> assign(:chat_messages, [])
       |> assign(:show_delete_confirm, false)
       |> put_flash(:info, "Chat history deleted")}
    else
      {:noreply, assign(socket, :show_delete_confirm, false)}
    end
  end

  # Leave current conversation
  defp leave_conversation(socket) do
    if socket.assigns.current_topic do
      Phoenix.PubSub.unsubscribe(ChatService.PubSub, socket.assigns.current_topic)
    end

    socket
    |> assign(:current_topic, nil)
    |> assign(:viewing_admins, [])
    |> assign(:typing_admins, [])
  end

  # Broadcast typing status
  defp broadcast_typing(socket, typing) do
    if socket.assigns.current_topic do
      Phoenix.PubSub.broadcast(
        ChatService.PubSub,
        socket.assigns.current_topic,
        {:admin_typing, %{
          admin_id: socket.assigns.admin_id,
          topic: socket.assigns.current_topic,
          typing: typing
        }}
      )
    end
  end

  # Save base64 image to disk and return public URL
  defp save_image_from_base64(base64_data, filename) do
    require Logger

    try do
      # Parse base64 data URL
      case Regex.run(~r/^data:image\/(\w+);base64,(.+)$/, base64_data) do
        [_, _ext, data] ->
          # Decode base64
          case Base.decode64(data) do
            {:ok, binary} ->
              # Generate unique filename
              timestamp = System.system_time(:millisecond)
              random = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
              safe_name = String.replace(filename, ~r/[^a-zA-Z0-9._-]/, "_")
              final_name = "#{timestamp}_#{random}_#{safe_name}"

              # Ensure uploads directory exists
              uploads_dir = Path.join([:code.priv_dir(:chat_service), "static", "uploads"])
              File.mkdir_p!(uploads_dir)

              # Write file
              file_path = Path.join(uploads_dir, final_name)
              File.write!(file_path, binary)

              # Return public URL
              "/uploads/#{final_name}"

            :error ->
              Logger.error("Failed to decode base64 image data")
              nil
          end

        _ ->
          Logger.error("Invalid base64 image data format")
          nil
      end
    rescue
      e ->
        Logger.error("Error saving image: #{inspect(e)}")
        nil
    end
  end

  # Data functions
  defp list_users_with_unread(channel_id \\ nil) do
    base_query = User
      |> join(:left, [u], c in Channel, on: u.channel_id == c.id)
      |> Ecto.Query.select([u, c], %{
        id: u.id,
        line_user_id: u.line_user_id,
        display_name: u.display_name,
        picture_url: u.picture_url,
        tags: u.tags,
        notes: u.notes,
        last_interaction_at: u.last_interaction_at,
        channel_id: c.id,
        channel_name: c.name,
        channel_line_id: c.channel_id
      })
      |> order_by([u], desc: u.last_interaction_at)
      |> limit(100)

    query = if channel_id do
      base_query |> where([u, c], c.channel_id == ^channel_id)
    else
      base_query
    end

    users = Repo.all(query)

    Enum.map(users, fn user ->
      unread_count = get_unread_count(user.line_user_id, user.channel_id)
      last_message = get_last_message(user.line_user_id, user.channel_id)
      Map.merge(user, %{unread_count: unread_count, last_message: last_message})
    end)
  end

  defp get_unread_count(user_id, channel_id) do
    Message
    |> where([m], m.user_id == ^user_id and m.channel_id == ^channel_id)
    |> where([m], m.direction == :incoming and m.is_read == false)
    |> Repo.aggregate(:count, :id)
  rescue
    _ -> 0
  end

  defp get_last_message(user_id, channel_id) do
    Message
    |> where([m], m.user_id == ^user_id and m.channel_id == ^channel_id)
    |> order_by([m], desc: m.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp load_user_messages(user_id, channel_id) do
    Message
    |> where([m], m.user_id == ^user_id and m.channel_id == ^channel_id)
    |> order_by([m], desc: m.inserted_at)
    |> limit(50)
    |> preload(:channel)
    |> Repo.all()
    |> Enum.reverse()
  end

  defp mark_messages_as_read(user_id, channel_id) do
    Message
    |> where([m], m.user_id == ^user_id and m.channel_id == ^channel_id)
    |> where([m], m.direction == :incoming and m.is_read == false)
    |> Repo.update_all(set: [is_read: true, read_at: DateTime.utc_now()])
  rescue
    _ -> :ok
  end

  defp list_channels do
    Channel
    |> where([c], c.is_active == true)
    |> order_by([c], asc: c.name)
    |> Repo.all()
  end

  defp get_channel_by_id(channel_id) do
    Repo.get(Channel, channel_id)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-[calc(100vh-120px)]">
      <!-- Header -->
      <div class="flex justify-between items-center mb-4">
        <div class="flex items-center gap-3">
          <h1 class="text-2xl font-bold text-white">Conversations</h1>
          <!-- Online Admins Indicator -->
          <div class="flex items-center gap-2 px-3 py-1.5 bg-slate-800 rounded-full border border-slate-700">
            <div class="w-2 h-2 bg-emerald-500 rounded-full animate-pulse"></div>
            <span class="text-xs text-slate-400">
              <%= length(@online_admins) %> admin<%= if length(@online_admins) != 1, do: "s" %> online
            </span>
            <!-- Admin Avatars -->
            <div class="flex -space-x-2">
              <%= for admin <- Enum.take(@online_admins, 5) do %>
                <div
                  class="w-6 h-6 rounded-full flex items-center justify-center text-xs font-bold text-white border-2 border-slate-800"
                  style={"background-color: #{admin.color}"}
                  title={admin.name}
                >
                  <%= String.first(admin.name) %>
                </div>
              <% end %>
              <%= if length(@online_admins) > 5 do %>
                <div class="w-6 h-6 rounded-full bg-slate-600 flex items-center justify-center text-xs text-white border-2 border-slate-800">
                  +<%= length(@online_admins) - 5 %>
                </div>
              <% end %>
            </div>
          </div>
        </div>
        <div class="flex items-center gap-4">
          <!-- Your Admin Badge -->
          <div class="flex items-center gap-2 px-3 py-1.5 bg-slate-700/50 rounded-lg border border-slate-600">
            <div
              class="w-3 h-3 rounded-full"
              style={"background-color: #{@admin_color}"}
            ></div>
            <span class="text-xs text-slate-300"><%= @admin_name %></span>
          </div>
          <select
            phx-change="filter_channel"
            name="channel"
            class="px-3 py-2 bg-slate-700 border border-slate-600 rounded-lg text-sm text-white"
          >
            <option value="">All Channels</option>
            <%= for channel <- @channels do %>
              <option value={channel.channel_id} selected={@selected_channel == channel.channel_id}>
                <%= channel.name || channel.channel_id %>
              </option>
            <% end %>
          </select>
          <div class="flex bg-slate-700 rounded-lg p-1">
            <button
              phx-click="change_view"
              phx-value-mode="chats"
              class={"px-3 py-1 rounded text-sm transition #{if @view_mode == "chats", do: "bg-emerald-500 text-white", else: "text-slate-300 hover:text-white"}"}
            >
              Chats
            </button>
            <button
              phx-click="change_view"
              phx-value-mode="realtime"
              class={"px-3 py-1 rounded text-sm transition #{if @view_mode == "realtime", do: "bg-emerald-500 text-white", else: "text-slate-300 hover:text-white"}"}
            >
              Real-time
            </button>
          </div>
        </div>
      </div>

      <%= if @view_mode == "chats" do %>
        <!-- Chat View -->
        <div class="flex gap-4 h-full">
          <!-- User List -->
          <div class="w-80 bg-slate-900 rounded-xl border border-slate-700 overflow-hidden flex flex-col">
            <div class="p-4 border-b border-slate-700 bg-slate-800">
              <h2 class="font-semibold text-white">Users (<%= length(@users) %>)</h2>
            </div>
            <div class="flex-1 overflow-y-auto">
              <%= if @users == [] do %>
                <div class="p-8 text-center text-slate-500">
                  <svg class="w-12 h-12 mx-auto mb-3 text-slate-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17 20h5v-2a3 3 0 00-5.356-1.857M17 20H7m10 0v-2c0-.656-.126-1.283-.356-1.857M7 20H2v-2a3 3 0 015.356-1.857M7 20v-2c0-.656.126-1.283.356-1.857m0 0a5.002 5.002 0 019.288 0M15 7a3 3 0 11-6 0 3 3 0 016 0zm6 3a2 2 0 11-4 0 2 2 0 014 0zM7 10a2 2 0 11-4 0 2 2 0 014 0z"/>
                  </svg>
                  <p>No users yet</p>
                  <p class="text-xs mt-1">Send a message from LINE</p>
                </div>
              <% else %>
                <%= for user <- @users do %>
                  <div
                    phx-click="select_user"
                    phx-value-user-id={user.line_user_id}
                    class={"p-3 border-b border-slate-800 cursor-pointer transition-colors #{if @selected_user && @selected_user.line_user_id == user.line_user_id, do: "bg-emerald-900/30 border-l-4 border-l-emerald-500", else: "hover:bg-slate-800"}"}
                  >
                    <div class="flex items-center gap-3">
                      <%= if user.picture_url do %>
                        <img src={user.picture_url} class="w-12 h-12 rounded-full object-cover ring-2 ring-slate-700" />
                      <% else %>
                        <div class="w-12 h-12 rounded-full bg-gradient-to-br from-slate-600 to-slate-700 flex items-center justify-center text-slate-400 ring-2 ring-slate-700">
                          <svg class="w-6 h-6" fill="currentColor" viewBox="0 0 20 20">
                            <path fill-rule="evenodd" d="M10 9a3 3 0 100-6 3 3 0 000 6zm-7 9a7 7 0 1114 0H3z" clip-rule="evenodd"/>
                          </svg>
                        </div>
                      <% end %>

                      <div class="flex-1 min-w-0">
                        <div class="flex items-center justify-between">
                          <span class="font-medium text-white truncate">
                            <%= user.display_name || truncate_user_id(user.line_user_id) %>
                          </span>
                          <%= if user.unread_count > 0 do %>
                            <span class="bg-red-500 text-white text-xs font-bold px-2 py-0.5 rounded-full min-w-[20px] text-center">
                              <%= user.unread_count %>
                            </span>
                          <% end %>
                        </div>
                        <p class="text-sm text-slate-400 truncate mt-0.5">
                          <%= if user.last_message do %>
                            <%= truncate_text(user.last_message.content, 25) %>
                          <% else %>
                            No messages
                          <% end %>
                        </p>
                        <%= if user.tags && user.tags != [] do %>
                          <div class="flex flex-wrap gap-1 mt-1">
                            <%= for tag <- Enum.take(user.tags, 2) do %>
                              <span class="text-xs px-1.5 py-0.5 bg-cyan-500/20 text-cyan-400 rounded">
                                <%= tag %>
                              </span>
                            <% end %>
                          </div>
                        <% end %>
                      </div>
                    </div>
                  </div>
                <% end %>
              <% end %>
            </div>
          </div>

          <!-- Chat Area -->
          <div class="flex-1 bg-slate-800 rounded-xl border border-slate-700 overflow-hidden flex flex-col">
            <%= if @selected_user do %>
              <!-- Chat Header -->
              <div class="p-4 border-b border-slate-700 bg-emerald-900/50 flex items-center justify-between">
                <div class="flex items-center gap-3">
                  <%= if @selected_user.picture_url do %>
                    <img src={@selected_user.picture_url} class="w-11 h-11 rounded-full object-cover ring-2 ring-emerald-500/50" />
                  <% else %>
                    <div class="w-11 h-11 rounded-full bg-gradient-to-br from-emerald-600 to-emerald-700 flex items-center justify-center text-white ring-2 ring-emerald-500/50">
                      <svg class="w-6 h-6" fill="currentColor" viewBox="0 0 20 20">
                        <path fill-rule="evenodd" d="M10 9a3 3 0 100-6 3 3 0 000 6zm-7 9a7 7 0 1114 0H3z" clip-rule="evenodd"/>
                      </svg>
                    </div>
                  <% end %>
                  <div>
                    <h3 class="font-semibold text-white text-lg"><%= @selected_user.display_name || "Unknown" %></h3>
                    <p class="text-xs text-emerald-300/70"><%= @selected_user.channel_name %></p>
                  </div>
                </div>
                <div class="flex items-center gap-3">
                  <!-- Other Admins Viewing -->
                  <%= if @viewing_admins != [] do %>
                    <div class="flex items-center gap-2 px-3 py-1.5 bg-slate-800/50 rounded-full">
                      <svg class="w-4 h-4 text-slate-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"/>
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"/>
                      </svg>
                      <div class="flex -space-x-1">
                        <%= for admin <- @viewing_admins do %>
                          <div
                            class="w-5 h-5 rounded-full flex items-center justify-center text-[10px] font-bold text-white border border-slate-700"
                            style={"background-color: #{admin.color}"}
                            title={"#{admin.name} is viewing"}
                          >
                            <%= String.first(admin.name) %>
                          </div>
                        <% end %>
                      </div>
                      <span class="text-xs text-slate-400">viewing</span>
                    </div>
                  <% end %>
                  <button
                    phx-click="edit_user"
                    phx-value-user-id={@selected_user.line_user_id}
                    class="p-2 hover:bg-emerald-800/50 rounded-lg transition-colors"
                    title="Edit tags/notes"
                  >
                    <svg class="w-5 h-5 text-emerald-300" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M7 7h.01M7 3h5c.512 0 1.024.195 1.414.586l7 7a2 2 0 010 2.828l-7 7a2 2 0 01-2.828 0l-7-7A1.994 1.994 0 013 12V7a4 4 0 014-4z"/>
                    </svg>
                  </button>
                  <button
                    phx-click="confirm_delete_chat"
                    class="p-2 hover:bg-red-800/50 rounded-lg transition-colors"
                    title="Delete chat history"
                  >
                    <svg class="w-5 h-5 text-red-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"/>
                    </svg>
                  </button>
                </div>
              </div>

              <!-- Messages -->
              <div class="flex-1 overflow-y-auto p-4 space-y-3 bg-gradient-to-b from-slate-800 to-slate-900" id="chat-messages" phx-hook="ScrollToBottom">
                <%= for msg <- @chat_messages do %>
                  <div class={"flex #{if msg.direction == :incoming, do: "justify-start", else: "justify-end"}"}>
                    <div class={"max-w-[70%] rounded-2xl shadow-lg #{if msg.direction == :incoming, do: "bg-white text-slate-800 rounded-bl-sm", else: "bg-emerald-500 text-white rounded-br-sm"}"}>
                      <%= if msg.message_type == "image" do %>
                        <!-- Image Message -->
                        <div class="p-1">
                          <img
                            src={msg.metadata["image_url"] || msg.content}
                            class="rounded-xl max-w-full max-h-64 object-cover cursor-pointer hover:opacity-90 transition"
                            phx-click="view_image"
                            phx-value-url={msg.metadata["image_url"] || msg.content}
                          />
                        </div>
                        <div class={"px-3 pb-2 flex items-center gap-2 #{if msg.direction == :incoming, do: "text-slate-400", else: "text-emerald-100"}"}>
                          <span class="text-xs"><%= Calendar.strftime(msg.inserted_at, "%H:%M") %></span>
                          <%= if msg.direction == :outgoing && msg.metadata["admin_name"] do %>
                            <span class="text-xs opacity-75">by <%= msg.metadata["admin_name"] %></span>
                          <% end %>
                        </div>
                      <% else %>
                        <!-- Text Message -->
                        <div class="p-3">
                          <p class="text-sm whitespace-pre-wrap leading-relaxed"><%= msg.content %></p>
                          <div class={"flex items-center gap-2 mt-1 #{if msg.direction == :incoming, do: "text-slate-400", else: "text-emerald-100"}"}>
                            <span class="text-xs"><%= Calendar.strftime(msg.inserted_at, "%H:%M") %></span>
                            <%= if msg.direction == :outgoing && msg.metadata["admin_name"] do %>
                              <span class="text-xs opacity-75">by <%= msg.metadata["admin_name"] %></span>
                            <% end %>
                          </div>
                        </div>
                      <% end %>
                    </div>
                  </div>
                <% end %>

                <!-- Typing Indicator -->
                <%= if @typing_admins != [] do %>
                  <div class="flex justify-end">
                    <div class="flex items-center gap-2 px-4 py-2 bg-slate-700/50 rounded-full">
                      <div class="flex -space-x-1">
                        <%= for admin <- @typing_admins do %>
                          <div
                            class="w-5 h-5 rounded-full flex items-center justify-center text-[10px] font-bold text-white"
                            style={"background-color: #{admin[:color] || AdminPresence.generate_color(admin.admin_id)}"}
                          >
                            <%= String.first(admin.name || "A") %>
                          </div>
                        <% end %>
                      </div>
                      <div class="flex gap-1">
                        <div class="w-2 h-2 bg-slate-400 rounded-full animate-bounce" style="animation-delay: 0ms"></div>
                        <div class="w-2 h-2 bg-slate-400 rounded-full animate-bounce" style="animation-delay: 150ms"></div>
                        <div class="w-2 h-2 bg-slate-400 rounded-full animate-bounce" style="animation-delay: 300ms"></div>
                      </div>
                      <span class="text-xs text-slate-400">typing...</span>
                    </div>
                  </div>
                <% end %>
              </div>

              <!-- Image Preview -->
              <%= if @pending_images != [] do %>
                <div class="p-3 border-t border-slate-700 bg-slate-800">
                  <div class="flex items-center gap-2 mb-2">
                    <span class="text-xs text-slate-400"><%= length(@pending_images) %> image(s) selected</span>
                    <button phx-click="clear_images" class="text-xs text-red-400 hover:text-red-300">Clear all</button>
                  </div>
                  <div class="flex gap-2 overflow-x-auto pb-2">
                    <%= for {entry, index} <- Enum.with_index(@pending_images) do %>
                      <div class="relative flex-shrink-0 group">
                        <img src={entry.preview} class="w-20 h-20 object-cover rounded-lg border border-slate-600" />
                        <button
                          phx-click="remove_image"
                          phx-value-index={index}
                          class="absolute -top-2 -right-2 w-5 h-5 bg-red-500 text-white rounded-full flex items-center justify-center opacity-0 group-hover:opacity-100 transition"
                        >
                          <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/>
                          </svg>
                        </button>
                      </div>
                    <% end %>
                  </div>
                  <button
                    phx-click="send_images"
                    disabled={@sending}
                    class="w-full py-2 bg-emerald-500 text-white rounded-lg hover:bg-emerald-600 disabled:opacity-50 text-sm font-medium transition"
                  >
                    <%= if @sending do %>
                      Sending...
                    <% else %>
                      Send <%= length(@pending_images) %> Image(s)
                    <% end %>
                  </button>
                </div>
              <% end %>

              <!-- Error Message -->
              <%= if @send_error do %>
                <div class="mx-4 mt-2 p-3 bg-red-500/20 border border-red-500/50 rounded-lg flex items-center justify-between">
                  <div class="flex items-center gap-2">
                    <svg class="w-5 h-5 text-red-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/>
                    </svg>
                    <span class="text-sm text-red-300"><%= @send_error %></span>
                  </div>
                  <button phx-click="clear_error" class="text-red-400 hover:text-red-300">
                    <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/>
                    </svg>
                  </button>
                </div>
              <% end %>

              <!-- Message Input -->
              <div class="p-4 border-t border-slate-700 bg-slate-900">
                <!-- Image URL Input -->
                <form phx-submit="send_image_url" phx-change="update_image_url" class="flex gap-2 mb-3">
                  <input
                    type="text"
                    name="url"
                    value={@image_url_input}
                    placeholder="Paste image URL (https://...)..."
                    autocomplete="off"
                    class="flex-1 px-4 py-2 bg-slate-800 border border-slate-600 rounded-lg text-white text-sm placeholder-slate-500 focus:outline-none focus:border-cyan-500 focus:ring-1 focus:ring-cyan-500"
                  />
                  <button
                    type="submit"
                    disabled={@image_url_input == "" || @sending}
                    class="px-4 py-2 bg-cyan-600 text-white rounded-lg hover:bg-cyan-500 disabled:opacity-50 disabled:cursor-not-allowed text-sm transition-colors flex items-center gap-1"
                  >
                    <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 16l4.586-4.586a2 2 0 012.828 0L16 16m-2-2l1.586-1.586a2 2 0 012.828 0L20 14m-6-6h.01M6 20h12a2 2 0 002-2V6a2 2 0 00-2-2H6a2 2 0 00-2 2v12a2 2 0 002 2z"/>
                    </svg>
                    Send URL
                  </button>
                </form>

                <!-- Text Message Form -->
                <form phx-submit="send_message" phx-change="update_reply" class="flex gap-2">
                  <!-- Image Upload Button (for local files - requires public URL config) -->
                  <label class="p-3 bg-slate-800 border border-slate-600 rounded-full hover:bg-slate-700 cursor-pointer transition-colors flex items-center justify-center" title="Upload local image (requires public URL config)">
                    <input
                      type="file"
                      accept="image/*"
                      multiple
                      class="hidden"
                      phx-hook="ImageUpload"
                      id="image-upload"
                    />
                    <svg class="w-5 h-5 text-slate-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 16l4.586-4.586a2 2 0 012.828 0L16 16m-2-2l1.586-1.586a2 2 0 012.828 0L20 14m-6-6h.01M6 20h12a2 2 0 002-2V6a2 2 0 00-2-2H6a2 2 0 00-2 2v12a2 2 0 002 2z"/>
                    </svg>
                  </label>
                  <input
                    type="text"
                    name="message"
                    value={@reply_text}
                    placeholder="Type a message..."
                    autocomplete="off"
                    class="flex-1 px-4 py-3 bg-slate-800 border border-slate-600 rounded-full text-white placeholder-slate-400 focus:outline-none focus:border-emerald-500 focus:ring-1 focus:ring-emerald-500"
                    phx-debounce="100"
                  />
                  <button
                    type="submit"
                    disabled={@reply_text == "" || @sending}
                    class="px-5 py-3 bg-emerald-500 text-white rounded-full hover:bg-emerald-600 disabled:opacity-50 disabled:cursor-not-allowed flex items-center gap-2 transition-colors"
                  >
                    <%= if @sending do %>
                      <svg class="animate-spin h-5 w-5" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
                        <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                        <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
                      </svg>
                    <% else %>
                      <svg class="w-5 h-5" fill="currentColor" viewBox="0 0 20 20">
                        <path d="M10.894 2.553a1 1 0 00-1.788 0l-7 14a1 1 0 001.169 1.409l5-1.429A1 1 0 009 15.571V11a1 1 0 112 0v4.571a1 1 0 00.725.962l5 1.428a1 1 0 001.17-1.408l-7-14z"/>
                      </svg>
                    <% end %>
                  </button>
                </form>
              </div>
            <% else %>
              <div class="flex-1 flex items-center justify-center bg-gradient-to-b from-slate-800 to-slate-900">
                <div class="text-center">
                  <div class="w-20 h-20 mx-auto mb-4 bg-slate-700 rounded-full flex items-center justify-center">
                    <svg class="w-10 h-10 text-slate-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 12h.01M12 12h.01M16 12h.01M21 12c0 4.418-4.03 8-9 8a9.863 9.863 0 01-4.255-.949L3 20l1.395-3.72C3.512 15.042 3 13.574 3 12c0-4.418 4.03-8 9-8s9 3.582 9 8z"/>
                    </svg>
                  </div>
                  <p class="text-slate-400 text-lg">Select a conversation</p>
                  <p class="text-slate-500 text-sm mt-1">Choose a user from the list</p>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      <% else %>
        <!-- Real-time Webhook View -->
        <div class="bg-slate-800 rounded-xl border border-slate-700 overflow-hidden">
          <div class="p-4 border-b border-slate-700 bg-slate-900 flex justify-between items-center">
            <div class="flex items-center gap-2">
              <div class="w-2 h-2 bg-emerald-500 rounded-full animate-pulse"></div>
              <h2 class="font-semibold text-white">Webhook Logs (Raw)</h2>
            </div>
            <button
              phx-click="clear_logs"
              class="px-3 py-1.5 text-xs bg-slate-700 rounded-lg hover:bg-slate-600 text-slate-300 transition-colors"
            >
              Clear
            </button>
          </div>
          <div class="max-h-[600px] overflow-y-auto">
            <%= if @webhook_logs == [] do %>
              <div class="p-8 text-center text-slate-500">
                <svg class="w-12 h-12 mx-auto mb-3 text-slate-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z"/>
                </svg>
                <p class="text-slate-400">Waiting for webhooks...</p>
                <p class="text-xs mt-1 text-slate-500">Send a message to your LINE OA</p>
              </div>
            <% else %>
              <%= for log <- @webhook_logs do %>
                <div class="p-3 border-b border-slate-700/50 hover:bg-slate-700/30 transition-colors">
                  <div class="flex justify-between items-start mb-2">
                    <span class={"px-2 py-0.5 rounded text-xs font-medium #{event_color(log.event_type)}"}>
                      <%= log.event_type %>
                    </span>
                    <span class="text-xs text-slate-500">
                      <%= Calendar.strftime(log.timestamp, "%H:%M:%S") %>
                    </span>
                  </div>
                  <div class="text-xs space-y-1 text-slate-300">
                    <p><span class="text-slate-500">Channel:</span> <%= log.channel_id %></p>
                    <p><span class="text-slate-500">User:</span> <span class="text-cyan-400 font-mono"><%= truncate_user_id(log.user_id) %></span></p>
                    <%= if log[:message_type] do %>
                      <p><span class="text-slate-500">Type:</span> <%= log.message_type %></p>
                    <% end %>
                    <%= if log[:message_text] do %>
                      <p class="mt-1 p-2 bg-slate-900/50 rounded text-slate-300">
                        "<%= truncate_text(log.message_text, 100) %>"
                      </p>
                    <% end %>
                  </div>
                  <details class="mt-2">
                    <summary class="text-xs text-slate-400 cursor-pointer hover:text-white transition-colors">
                      Raw Data
                    </summary>
                    <pre class="mt-2 p-2 bg-slate-900 rounded text-xs overflow-x-auto text-emerald-400"><%= Jason.encode!(log.raw, pretty: true) %></pre>
                  </details>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>
      <% end %>

      <!-- Edit User Modal -->
      <%= if @editing_user do %>
        <div class="fixed inset-0 bg-black/60 backdrop-blur-sm flex items-center justify-center z-50">
          <div class="bg-slate-800 rounded-2xl border border-slate-700 w-full max-w-md p-6 shadow-2xl">
            <div class="flex items-center justify-between mb-4">
              <h3 class="text-lg font-semibold text-white">Edit User</h3>
              <button phx-click="close_edit" class="text-slate-400 hover:text-white transition-colors p-1 rounded-lg hover:bg-slate-700">
                <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/>
                </svg>
              </button>
            </div>

            <div class="flex items-center gap-3 mb-4 p-3 bg-slate-700/50 rounded-xl border border-slate-600">
              <%= if @editing_user.picture_url do %>
                <img src={@editing_user.picture_url} class="w-12 h-12 rounded-full ring-2 ring-emerald-500/50" />
              <% else %>
                <div class="w-12 h-12 rounded-full bg-gradient-to-br from-slate-600 to-slate-700 flex items-center justify-center ring-2 ring-slate-600">
                  <svg class="w-6 h-6 text-slate-400" fill="currentColor" viewBox="0 0 20 20">
                    <path fill-rule="evenodd" d="M10 9a3 3 0 100-6 3 3 0 000 6zm-7 9a7 7 0 1114 0H3z" clip-rule="evenodd"/>
                  </svg>
                </div>
              <% end %>
              <div>
                <p class="font-medium text-white"><%= @editing_user.display_name || "Unknown" %></p>
                <p class="text-xs text-slate-400"><%= truncate_user_id(@editing_user.line_user_id) %></p>
              </div>
            </div>

            <form phx-submit="save_user" class="space-y-4">
              <div>
                <label class="block text-sm text-slate-400 mb-1.5">Tags (comma separated)</label>
                <input
                  type="text"
                  name="tags"
                  value={@user_form["tags"]}
                  placeholder="VIP, New, Support"
                  class="w-full px-4 py-2.5 bg-slate-900 border border-slate-600 rounded-xl text-sm text-white placeholder-slate-500 focus:outline-none focus:border-emerald-500 focus:ring-1 focus:ring-emerald-500"
                />
              </div>

              <div>
                <label class="block text-sm text-slate-400 mb-1.5">Notes</label>
                <textarea
                  name="notes"
                  rows="3"
                  placeholder="Add notes about this user..."
                  class="w-full px-4 py-2.5 bg-slate-900 border border-slate-600 rounded-xl text-sm text-white placeholder-slate-500 focus:outline-none focus:border-emerald-500 focus:ring-1 focus:ring-emerald-500"
                ><%= @user_form["notes"] %></textarea>
              </div>

              <div class="flex justify-end gap-3 pt-2">
                <button
                  type="button"
                  phx-click="close_edit"
                  class="px-4 py-2.5 bg-slate-700 text-slate-300 rounded-xl hover:bg-slate-600 transition-colors"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  class="px-5 py-2.5 bg-emerald-500 text-white rounded-xl hover:bg-emerald-600 transition-colors font-medium"
                >
                  Save
                </button>
              </div>
            </form>
          </div>
        </div>
      <% end %>

      <!-- Image View Modal -->
      <%= if @image_modal do %>
        <div
          class="fixed inset-0 bg-black/90 backdrop-blur-sm flex items-center justify-center z-50"
          phx-click="close_image_modal"
        >
          <div class="relative max-w-[90vw] max-h-[90vh]">
            <button
              phx-click="close_image_modal"
              class="absolute -top-12 right-0 text-white hover:text-slate-300 transition-colors p-2"
            >
              <svg class="w-8 h-8" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/>
              </svg>
            </button>
            <img
              src={@image_modal}
              class="max-w-full max-h-[85vh] object-contain rounded-lg shadow-2xl"
              phx-click="close_image_modal"
            />
            <a
              href={@image_modal}
              target="_blank"
              class="absolute bottom-4 right-4 px-4 py-2 bg-white/10 backdrop-blur-sm text-white rounded-lg hover:bg-white/20 transition-colors flex items-center gap-2"
            >
              <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"/>
              </svg>
              Open original
            </a>
          </div>
        </div>
      <% end %>

      <!-- Delete Confirmation Modal -->
      <%= if @show_delete_confirm && @selected_user do %>
        <div class="fixed inset-0 bg-black/60 backdrop-blur-sm flex items-center justify-center z-50">
          <div class="bg-slate-800 rounded-2xl border border-slate-700 w-full max-w-md p-6 shadow-2xl">
            <div class="flex items-center gap-3 mb-4">
              <div class="w-12 h-12 bg-red-500/20 rounded-full flex items-center justify-center">
                <svg class="w-6 h-6 text-red-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"/>
                </svg>
              </div>
              <div>
                <h3 class="text-lg font-semibold text-white">Delete Chat History</h3>
                <p class="text-sm text-slate-400">This action cannot be undone</p>
              </div>
            </div>

            <div class="p-4 bg-slate-900/50 rounded-xl mb-4">
              <p class="text-slate-300 text-sm">
                Are you sure you want to delete all messages with
                <span class="font-semibold text-white"><%= @selected_user.display_name || "this user" %></span>?
              </p>
              <p class="text-xs text-slate-500 mt-2">
                <%= length(@chat_messages) %> message(s) will be permanently deleted.
              </p>
            </div>

            <div class="flex justify-end gap-3">
              <button
                phx-click="cancel_delete"
                class="px-4 py-2.5 bg-slate-700 text-slate-300 rounded-xl hover:bg-slate-600 transition-colors"
              >
                Cancel
              </button>
              <button
                phx-click="delete_chat"
                class="px-5 py-2.5 bg-red-500 text-white rounded-xl hover:bg-red-600 transition-colors font-medium flex items-center gap-2"
              >
                <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"/>
                </svg>
                Delete
              </button>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # Helper functions
  defp event_color("message"), do: "bg-cyan-500/20 text-cyan-400"
  defp event_color("follow"), do: "bg-emerald-500/20 text-emerald-400"
  defp event_color("unfollow"), do: "bg-red-500/20 text-red-400"
  defp event_color("postback"), do: "bg-violet-500/20 text-violet-400"
  defp event_color(_), do: "bg-slate-500/20 text-slate-400"

  defp truncate_user_id(nil), do: "-"
  defp truncate_user_id(user_id) when is_binary(user_id) do
    if String.length(user_id) > 12 do
      String.slice(user_id, 0, 8) <> "..." <> String.slice(user_id, -4, 4)
    else
      user_id
    end
  end

  defp truncate_text(nil, _max), do: ""
  defp truncate_text(text, max) when is_binary(text) do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "..."
    else
      text
    end
  end
end
