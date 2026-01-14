defmodule ChatService do
  @moduledoc false

  def version do
    Application.spec(:chat_service, :vsn) |> to_string()
  end

  def backend_url do
    Application.get_env(:chat_service, :backend_url, "http://localhost:8000")
  end

  def port do
    Application.get_env(:chat_service, :port, 8888)
  end
end
