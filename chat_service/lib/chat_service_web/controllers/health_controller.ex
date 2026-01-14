defmodule ChatServiceWeb.HealthController do
  use ChatServiceWeb, :controller

  def check(conn, _params) do
    checks = %{
      redis: check_redis(),
      backend: check_backend(),
      memory: check_memory(),
      processes: check_processes()
    }

    status = if Enum.all?(checks, fn {_, v} -> v.status == :ok end), do: :ok, else: :degraded

    json(conn, %{
      status: status,
      checks: checks,
      uptime_seconds: ChatService.Telemetry.uptime_seconds(),
      version: Application.spec(:chat_service, :vsn) |> to_string()
    })
  end

  defp check_redis do
    case ChatService.Redis.Client.command(["PING"]) do
      {:ok, "PONG"} -> %{status: :ok, latency_ms: 1}
      _ -> %{status: :error, message: "Redis unavailable"}
    end
  end

  defp check_backend do
    url = Application.get_env(:chat_service, :backend_url)
    case Req.get("#{url}/health", receive_timeout: 5000) do
      {:ok, %{status: 200}} -> %{status: :ok}
      _ -> %{status: :error, message: "Backend unavailable"}
    end
  end

  defp check_memory do
    memory = :erlang.memory(:total) / 1024 / 1024
    %{status: :ok, used_mb: Float.round(memory, 2)}
  end

  defp check_processes do
    count = :erlang.system_info(:process_count)
    limit = :erlang.system_info(:process_limit)
    %{status: :ok, count: count, limit: limit, usage_percent: Float.round(count / limit * 100, 2)}
  end
end
