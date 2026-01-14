defmodule ChatServiceWeb.AgentsController do
  use ChatServiceWeb, :controller
  require Logger

  def index(conn, _params) do
    agents = ChatService.Agents.Supervisor.list_agents()
    json(conn, %{agents: agents})
  end

  def create(conn, params) do
    case ChatService.Agents.Supervisor.start_agent(params) do
      {:ok, agent_id} ->
        conn
        |> put_status(:created)
        |> json(%{agent_id: agent_id, status: "created"})
      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: reason})
    end
  end

  def show(conn, %{"id" => agent_id}) do
    case ChatService.Agents.Supervisor.get_agent(agent_id) do
      {:ok, agent} ->
        json(conn, agent)
      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  def skills(conn, _params) do
    skills = [
      %{
        id: "web_search",
        name: "Web Search",
        description: "Search the web for information",
        category: "search"
      },
      %{
        id: "calculator",
        name: "Calculator",
        description: "Perform mathematical calculations",
        category: "utility"
      },
      %{
        id: "code_interpreter",
        name: "Code Interpreter",
        description: "Execute and analyze code",
        category: "code"
      },
      %{
        id: "file_reader",
        name: "File Reader",
        description: "Read and analyze documents",
        category: "document"
      },
      %{
        id: "rag_search",
        name: "RAG Search",
        description: "Search through knowledge base using RAG",
        category: "search"
      },
      %{
        id: "image_generation",
        name: "Image Generation",
        description: "Generate images from text descriptions",
        category: "creative"
      }
    ]

    json(conn, skills)
  end

  def chat(conn, %{"id" => agent_id} = params) do
    message = params["message"] || ""
    context = params["context"] || %{}

    case ChatService.Agents.Chat.process(agent_id, message, context) do
      {:ok, response} ->
        json(conn, %{response: response})
      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: reason})
    end
  end

  def stream(conn, %{"id" => agent_id} = params) do
    message = params["message"] || ""
    context = params["context"] || %{}

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    stream_response(conn, agent_id, message, context)
  end

  defp stream_response(conn, agent_id, message, context) do
    ChatService.Agents.Chat.stream(agent_id, message, context, fn
      {:chunk, text} ->
        chunk(conn, "data: #{Jason.encode!(%{type: "chunk", text: text})}\n\n")
      {:tool_call, tool, args} ->
        chunk(conn, "data: #{Jason.encode!(%{type: "tool_call", tool: tool, args: args})}\n\n")
      {:tool_result, tool, result} ->
        chunk(conn, "data: #{Jason.encode!(%{type: "tool_result", tool: tool, result: result})}\n\n")
      {:done, response} ->
        chunk(conn, "data: #{Jason.encode!(%{type: "done", response: response})}\n\n")
      {:error, reason} ->
        chunk(conn, "data: #{Jason.encode!(%{type: "error", error: reason})}\n\n")
    end)

    conn
  end
end
