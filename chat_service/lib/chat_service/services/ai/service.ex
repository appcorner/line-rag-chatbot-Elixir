defmodule ChatService.Services.Ai.Service do
  @moduledoc false

  require Logger
  import Ecto.Query

  alias ChatService.Agents.Chat
  alias ChatService.Repo
  alias ChatService.Schemas.Message

  @doc """
  Process a message using Elixir Agents.
  Returns {:ok, response_text} or {:error, reason}
  """
  def process_message(channel, user_id, text) do
    # Get AI settings from channel
    settings = channel.settings || channel[:settings] || %{}

    # Check if AI is enabled for this channel
    ai_enabled = get_setting(settings, "ai_enabled", true)

    if not ai_enabled do
      Logger.info("[AiService] AI disabled for channel #{channel.id || channel[:id]}")
      {:ok, :ai_disabled}
    else
      # Get API key (from channel settings or environment)
      api_key = get_api_key(settings)

      if is_nil(api_key) or api_key == "" do
        Logger.warning("[AiService] No API key configured for channel #{channel.id || channel[:id]}")
        {:ok, default_response(text)}
      else
        # Fetch conversation history (last 10 messages)
        channel_id = channel.id || channel[:id]
        history = get_conversation_history(channel_id, user_id, 10)

        # Get linked dataset info for RAG
        dataset_id = channel.dataset_id || channel[:dataset_id]

        # Check agent mode - explicitly convert to boolean
        agent_mode_raw = get_setting(settings, "agent_mode", false)
        agent_mode = agent_mode_raw == true
        Logger.info("[AiService] agent_mode_raw=#{inspect(agent_mode_raw)}, agent_mode=#{inspect(agent_mode)}, settings=#{inspect(Map.take(settings, ["agent_mode", :agent_mode]))}")

        if agent_mode do
          # Agent Mode: Use tools/skills
          Logger.info("[AiService] Taking AGENT MODE path")
          process_with_agent(channel, user_id, text, settings, api_key, history, dataset_id)
        else
          # Normal Mode: Direct RAG without tools
          Logger.info("[AiService] Taking NORMAL MODE path (no tools)")
          process_with_rag(channel, user_id, text, settings, api_key, history, dataset_id)
        end
      end
    end
  end

  # Agent Mode: Uses tools/skills for answering
  defp process_with_agent(_channel, user_id, text, settings, api_key, history, dataset_id) do
    {collection_name, dataset_prompt} = get_dataset_info(dataset_id)

    # Get selected skills or use defaults
    selected_skills = get_setting(settings, "selected_skills", [])
    base_skills = selected_skills

    # Auto-enable search_faq skill when dataset is linked
    skills = if collection_name, do: Enum.uniq(base_skills ++ ["search_faq"]), else: base_skills

    # Combine system prompt with FAQ instruction
    base_prompt = get_setting(settings, "system_prompt", nil)
    system_prompt = build_system_prompt(base_prompt, dataset_prompt, collection_name)

    request = %{
      message: text,
      api_key: api_key,
      provider: get_setting(settings, "llm_provider", "openai"),
      model: get_setting(settings, "llm_model", "gpt-4o-mini"),
      skills: skills,
      system_prompt: system_prompt,
      dataset_id: dataset_id,
      collection_name: collection_name,
      conversation_id: "agent:#{user_id}",
      history: history,
      max_tokens: parse_int_setting(settings, "max_tokens"),
      temperature: parse_float_setting(settings, "temperature")
    }

    Logger.info("[AiService] Agent Mode: provider=#{request.provider}, model=#{request.model}, user=#{user_id}, skills=#{inspect(skills)}")

    case Chat.process(request) do
      {:ok, response} ->
        Logger.info("[AiService] Agent response generated successfully")
        {:ok, response.message}

      {:error, reason} ->
        Logger.error("[AiService] Agent Error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Normal Mode: Direct RAG without tools
  defp process_with_rag(_channel, user_id, text, settings, api_key, history, dataset_id) do
    # Get RAG context from linked dataset (using channel's RAG settings)
    rag_context = get_rag_context(text, dataset_id, settings)

    # Build system prompt with RAG context
    base_prompt = get_setting(settings, "system_prompt", "คุณเป็นผู้ช่วยที่เป็นมิตร ตอบคำถามโดยอิงจากข้อมูลที่ให้มา")

    system_prompt = if rag_context && rag_context != "" do
      """
      🚨🚨🚨 คำสั่งสำคัญที่สุด - ต้องอ่านก่อน! 🚨🚨🚨

      คุณได้รับข้อมูล FAQ อย่างเป็นทางการจากฐานข้อมูลบริษัท:
      #{rag_context}

      📌 กฎเหล็ก (ละเมิดไม่ได้):
      1. ถ้าคำถามผู้ใช้ตรงกับ FAQ ด้านบน → ต้องตอบตาม "คำตอบที่ถูกต้อง" ใน FAQ เท่านั้น
      2. ห้ามเปลี่ยนข้อมูลสำคัญ เช่น เบอร์โทร, ราคา, ชื่อ, ขั้นตอน
      3. สามารถเพิ่มคำทักทายและ emoji ให้สุภาพได้ แต่ข้อมูลหลักต้องตรงกับ FAQ
      4. ถ้าไม่มี FAQ ที่เกี่ยวข้องเลย → ค่อยใช้ความรู้จาก persona ด้านล่าง

      ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
      🎭 Persona และ Guidelines ทั่วไป:
      #{base_prompt}
      """
    else
      base_prompt
    end

    request = %{
      message: text,
      api_key: api_key,
      provider: get_setting(settings, "llm_provider", "openai"),
      model: get_setting(settings, "llm_model", "gpt-4o-mini"),
      skills: [],  # No tools in normal mode
      system_prompt: system_prompt,
      dataset_id: dataset_id,
      collection_name: nil,
      conversation_id: "normal:#{user_id}",
      history: history,
      max_tokens: parse_int_setting(settings, "max_tokens"),
      temperature: parse_float_setting(settings, "temperature")
    }

    Logger.info("[AiService] Normal Mode: provider=#{request.provider}, model=#{request.model}, user=#{user_id}, skills=#{inspect(request.skills)}, has_rag=#{rag_context != nil and rag_context != ""}")

    case Chat.process(request) do
      {:ok, response} ->
        Logger.info("[AiService] Normal response generated successfully")
        {:ok, response.message}

      {:error, reason} ->
        Logger.error("[AiService] Normal Error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Get RAG context by searching the dataset directly
  defp get_rag_context(_text, nil, _channel_settings), do: nil
  defp get_rag_context(text, dataset_id, channel_settings) do
    alias ChatService.Schemas.Dataset
    alias ChatService.Services.Embedding.Service, as: EmbeddingService
    alias ChatService.VectorService.Client, as: VectorClient

    # Get RAG settings from channel (with defaults)
    rag_confidence = parse_rag_confidence(channel_settings)
    rag_top_k = parse_rag_top_k(channel_settings)

    Logger.info("[AiService] RAG settings: confidence=#{rag_confidence}, top_k=#{rag_top_k}")

    case Repo.get(Dataset, dataset_id) do
      nil -> nil
      dataset ->
        settings = dataset.settings || %{}
        provider = settings["embedding_provider"] || "openai"
        api_key = settings["embedding_api_key"]

        # Determine model based on dimension
        model = case dataset.dimension do
          3072 -> "text-embedding-3-large"
          1536 -> "text-embedding-3-small"
          768 -> "text-embedding-004"
          _ -> "text-embedding-3-small"
        end

        opts = [provider: provider, model: model]
        opts = if api_key && api_key != "", do: Keyword.put(opts, :api_key, api_key), else: opts

        # Generate embedding and search with configurable top_k
        Logger.info("[AiService] Starting embedding for query: #{String.slice(text, 0, 50)}...")
        embed_start = System.monotonic_time(:millisecond)

        # Use Task with timeout to prevent blocking
        embed_task = Task.async(fn -> EmbeddingService.embed(text, opts) end)
        embed_result = case Task.yield(embed_task, 35_000) || Task.shutdown(embed_task) do
          {:ok, result} -> result
          nil ->
            Logger.warning("[AiService] Embedding timed out after 35s")
            {:error, :timeout}
        end

        case embed_result do
          {:ok, embedding} ->
            embed_time = System.monotonic_time(:millisecond) - embed_start
            Logger.info("[AiService] Embedding completed in #{embed_time}ms")

            Logger.info("[AiService] Starting vector search (top_k=#{rag_top_k})...")
            search_start = System.monotonic_time(:millisecond)

            case VectorClient.search(dataset.collection_name, embedding, rag_top_k) do
              {:ok, %{results: results}} when results != [] ->
                search_time = System.monotonic_time(:millisecond) - search_start
                Logger.info("[AiService] Vector search completed in #{search_time}ms, found #{length(results)} results")

                # Format results for LLM context with configurable confidence threshold
                # Note: C++ service may not store metadata properly, so we also lookup from DB
                formatted = results
                |> Enum.with_index(1)
                |> Enum.map(fn {result, idx} ->
                  score = result[:score] || result["score"] || 0
                  vector_id = result[:id] || result["id"]

                  # Try to get metadata from vector, fallback to database
                  metadata = result[:metadata] || result["metadata"] || %{}
                  {question, answer} = if metadata == %{} or metadata == nil do
                    # Lookup from database using vector_id
                    case get_document_by_vector_id(dataset_id, vector_id) do
                      {:ok, doc} ->
                        {doc.question || "", doc.answer || doc.content || ""}
                      _ ->
                        {"", ""}
                    end
                  else
                    {
                      metadata["question"] || metadata[:question] || "",
                      metadata["answer"] || metadata[:answer] || metadata["content"] || metadata[:content] || ""
                    }
                  end

                  Logger.debug("[AiService] FAQ ##{idx}: score=#{score}, question=#{String.slice(question || "", 0, 50)}, answer=#{String.slice(answer || "", 0, 50)}")

                  if score >= rag_confidence and (question != "" or answer != "") do
                    """
                    ━━━ FAQ ##{idx} (ความเกี่ยวข้อง #{round(score * 100)}%) ━━━
                    ❓ คำถาม: #{question}
                    ✅ คำตอบที่ถูกต้อง: #{answer}
                    """
                  else
                    nil
                  end
                end)
                |> Enum.filter(& &1)
                |> Enum.join("\n")

                Logger.info("[AiService] RAG context ready, #{String.length(formatted || "")} chars")
                formatted

              {:ok, _} ->
                search_time = System.monotonic_time(:millisecond) - search_start
                Logger.info("[AiService] Vector search completed in #{search_time}ms, no results")
                nil

              {:error, reason} ->
                search_time = System.monotonic_time(:millisecond) - search_start
                Logger.warning("[AiService] Vector search failed in #{search_time}ms: #{inspect(reason)}")
                nil
            end

          {:error, reason} ->
            embed_time = System.monotonic_time(:millisecond) - embed_start
            Logger.warning("[AiService] Embedding failed in #{embed_time}ms: #{inspect(reason)}")
            nil
        end
    end
  rescue
    e ->
      Logger.warning("[AiService] RAG search error: #{inspect(e)}")
      nil
  end

  # Parse RAG confidence from settings (convert % to decimal, default 50%)
  defp parse_rag_confidence(settings) do
    case get_setting(settings, "rag_confidence", "50") do
      val when is_binary(val) ->
        case Integer.parse(val) do
          {num, _} -> num / 100.0
          :error -> 0.5
        end
      val when is_integer(val) -> val / 100.0
      val when is_float(val) -> val
      _ -> 0.5
    end
  end

  # Parse RAG top_k from settings (default 3)
  defp parse_rag_top_k(settings) do
    case get_setting(settings, "rag_top_k", "3") do
      val when is_binary(val) ->
        case Integer.parse(val) do
          {num, _} -> max(1, min(num, 20))
          :error -> 3
        end
      val when is_integer(val) -> max(1, min(val, 20))
      _ -> 3
    end
  end

  @doc """
  Process a message with detailed info (for testing/debugging).
  Returns {:ok, %{message: response, history: history, request: request}} or {:error, reason}
  """
  def process_message_with_details(channel, user_id, text, custom_history \\ nil) do
    settings = channel.settings || channel[:settings] || %{}
    ai_enabled = get_setting(settings, "ai_enabled", true)

    if not ai_enabled do
      {:ok, %{message: nil, status: :ai_disabled, history: [], request: nil}}
    else
      api_key = get_api_key(settings)

      if is_nil(api_key) or api_key == "" do
        {:ok, %{message: default_response(text), status: :no_api_key, history: [], request: nil}}
      else
        channel_id = channel.id || channel[:id]

        # Use custom history if provided, otherwise fetch from DB
        history = custom_history || get_conversation_history(channel_id, user_id, 10)

        # Get linked dataset info for FAQ search
        dataset_id = channel.dataset_id || channel[:dataset_id]
        {collection_name, dataset_prompt} = get_dataset_info(dataset_id)

        # Check agent mode - explicitly convert to boolean
        agent_mode_raw = get_setting(settings, "agent_mode", false)
        agent_mode = agent_mode_raw == true
        Logger.info("[AiService:Details] agent_mode_raw=#{inspect(agent_mode_raw)}, agent_mode=#{inspect(agent_mode)}")

        # Determine skills and system prompt based on agent mode
        {skills, system_prompt} = if agent_mode do
          # Agent Mode: Use tools/skills
          Logger.info("[AiService:Details] Taking AGENT MODE path")
          base_skills = get_setting(settings, "selected_skills", [])
          final_skills = if collection_name, do: Enum.uniq(base_skills ++ ["search_faq"]), else: base_skills

          base_prompt = get_setting(settings, "system_prompt", nil)
          final_prompt = build_system_prompt(base_prompt, dataset_prompt, collection_name)

          {final_skills, final_prompt}
        else
          # Normal Mode: Direct RAG without tools
          Logger.info("[AiService:Details] Taking NORMAL MODE path (no tools)")
          rag_context = get_rag_context(text, dataset_id, settings)
          base_prompt = get_setting(settings, "system_prompt", "คุณเป็นผู้ช่วยที่เป็นมิตร ตอบคำถามโดยอิงจากข้อมูลที่ให้มา")

          final_prompt = if rag_context && rag_context != "" do
            """
            #{base_prompt}

            ข้อมูลอ้างอิงจากฐานข้อมูล:
            #{rag_context}

            คำแนะนำ: ใช้ข้อมูลอ้างอิงด้านบนในการตอบคำถาม หากไม่พบข้อมูลที่เกี่ยวข้อง ให้ตอบตามความรู้ทั่วไป
            """
          else
            base_prompt
          end

          {[], final_prompt}  # Empty skills for normal mode
        end

        request = %{
          message: text,
          api_key: api_key,
          provider: get_setting(settings, "llm_provider", "openai"),
          model: get_setting(settings, "llm_model", "gpt-4o-mini"),
          skills: skills,
          system_prompt: system_prompt,
          dataset_id: dataset_id,
          collection_name: if(agent_mode, do: collection_name, else: nil),
          conversation_id: "#{channel_id}:#{user_id}",
          history: history,
          max_tokens: parse_int_setting(settings, "max_tokens"),
          temperature: parse_float_setting(settings, "temperature")
        }

        Logger.info("[AiService:Details] skills=#{inspect(skills)}, system_prompt_len=#{String.length(system_prompt || "")}")

        case Chat.process(request) do
          {:ok, response} ->
            {:ok, %{
              message: response.message,
              status: :success,
              history: history,
              request: %{
                provider: request.provider,
                model: request.model,
                skills: skills,
                agent_mode: agent_mode,
                system_prompt: request.system_prompt,
                dataset_id: request.dataset_id,
                collection_name: request.collection_name,
                history_count: length(history)
              }
            }}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  @doc """
  Health check for AI service.
  """
  def health_check do
    :ok
  end

  # Get setting value (supports both string and atom keys)
  defp get_setting(settings, key, default) do
    cond do
      Map.has_key?(settings, key) -> settings[key]
      Map.has_key?(settings, String.to_atom(key)) -> settings[String.to_atom(key)]
      true -> default
    end
  end

  # Parse integer setting
  defp parse_int_setting(settings, key) do
    case get_setting(settings, key, nil) do
      nil -> nil
      "" -> nil
      val when is_integer(val) -> val
      val when is_binary(val) ->
        case Integer.parse(val) do
          {int, _} -> int
          :error -> nil
        end
      _ -> nil
    end
  end

  # Parse float setting
  defp parse_float_setting(settings, key) do
    case get_setting(settings, key, nil) do
      nil -> nil
      "" -> nil
      val when is_float(val) -> val
      val when is_integer(val) -> val / 1
      val when is_binary(val) ->
        case Float.parse(val) do
          {float, _} -> float
          :error -> nil
        end
      _ -> nil
    end
  end

  # Fetch last N messages for conversation history
  defp get_conversation_history(channel_id, user_id, limit) do
    Message
    |> where([m], m.channel_id == ^channel_id and m.user_id == ^user_id)
    |> order_by([m], desc: m.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
    |> Enum.map(fn msg ->
      %{
        role: if(msg.direction == :incoming, do: "user", else: "assistant"),
        content: msg.content
      }
    end)
  rescue
    _ -> []
  end

  # Get API key from channel settings or environment
  defp get_api_key(settings) do
    settings["llm_api_key"] ||
      settings[:llm_api_key] ||
      settings["openai_api_key"] ||
      settings[:openai_api_key] ||
      Application.get_env(:chat_service, :openai_api_key) ||
      System.get_env("OPENAI_API_KEY")
  end

  # Get dataset info for FAQ search
  defp get_dataset_info(nil), do: {nil, nil}
  defp get_dataset_info(dataset_id) do
    alias ChatService.Schemas.Dataset
    case Repo.get(Dataset, dataset_id) do
      nil -> {nil, nil}
      dataset ->
        prompt = "คุณมีฐานข้อมูล FAQ ชื่อ '#{dataset.name}' ให้ใช้ search_faq tool ค้นหาคำตอบเมื่อผู้ใช้ถามคำถาม โดยใส่ collection_name: \"#{dataset.collection_name}\""
        {dataset.collection_name, prompt}
    end
  end

  # Get document from database by vector_id (fallback when C++ doesn't store metadata)
  defp get_document_by_vector_id(dataset_id, vector_id) when is_binary(vector_id) do
    alias ChatService.Schemas.Document

    case Document |> where([d], d.dataset_id == ^dataset_id and d.vector_id == ^vector_id) |> Repo.one() do
      nil -> {:error, :not_found}
      doc -> {:ok, doc}
    end
  rescue
    _ -> {:error, :database_error}
  end
  defp get_document_by_vector_id(_, _), do: {:error, :invalid_id}

  # Build system prompt with FAQ instruction
  defp build_system_prompt(nil, nil, _), do: nil
  defp build_system_prompt(nil, dataset_prompt, _), do: dataset_prompt
  defp build_system_prompt(base_prompt, nil, _), do: base_prompt
  defp build_system_prompt(base_prompt, dataset_prompt, _collection) do
    "#{base_prompt}\n\n#{dataset_prompt}"
  end

  # Default response when no API key is configured
  defp default_response(text) do
    cond do
      String.contains?(String.downcase(text), ["สวัสดี", "hello", "hi"]) ->
        "สวัสดีค่ะ มีอะไรให้ช่วยไหมคะ?"

      String.contains?(String.downcase(text), ["ขอบคุณ", "thank"]) ->
        "ยินดีค่ะ"

      true ->
        "ได้รับข้อความแล้วค่ะ"
    end
  end
end
