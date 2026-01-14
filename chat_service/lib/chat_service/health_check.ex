defmodule ChatService.HealthCheck do
  @moduledoc false

  alias ChatService.Services.Ai.Service, as: AiService

  def check_all do
    checks = [
      {:database, &check_database/0},
      {:ai_service, &check_ai_service/0}
    ]

    results = Enum.map(checks, fn {name, check_fn} ->
      {name, safe_check(check_fn)}
    end)

    failed = Enum.filter(results, fn {_, result} -> result != :ok end)

    if Enum.empty?(failed) do
      :ok
    else
      {:error, format_failures(failed)}
    end
  end

  def check_database do
    case ChatService.Repo.query("SELECT 1") do
      {:ok, _} -> :ok
      _ -> {:error, :database_unavailable}
    end
  end

  def check_ai_service do
    case AiService.health_check() do
      :ok -> :ok
      _ -> {:error, :ai_service_unavailable}
    end
  end

  defp safe_check(check_fn) do
    check_fn.()
  rescue
    _ -> {:error, :exception}
  end

  defp format_failures(failed) do
    failed
    |> Enum.map(fn {name, {:error, reason}} -> "#{name}: #{reason}" end)
    |> Enum.join(", ")
  end
end
