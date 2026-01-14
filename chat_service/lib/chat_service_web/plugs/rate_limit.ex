defmodule ChatServiceWeb.Plugs.RateLimit do
  import Plug.Conn
  require Logger

  def init(opts) do
    bucket = Keyword.get(opts, :bucket, :default)
    limits = Application.get_env(:chat_service, :rate_limits, %{})
    {window_ms, max_requests} = Map.get(limits, bucket, {60_000, 60})
    %{bucket: bucket, window_ms: window_ms, max_requests: max_requests}
  end

  def call(conn, %{bucket: bucket, window_ms: window_ms, max_requests: max_requests}) do
    key = rate_limit_key(conn, bucket)
    case Hammer.check_rate(key, window_ms, max_requests) do
      {:allow, count} ->
        conn
        |> put_resp_header("x-ratelimit-limit", to_string(max_requests))
        |> put_resp_header("x-ratelimit-remaining", to_string(max_requests - count))
      {:deny, _limit} ->
        Logger.warning("Rate limit exceeded for #{key}")
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(%{error: "rate_limit_exceeded"}))
        |> halt()
    end
  end

  defp rate_limit_key(conn, bucket) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()
    "#{bucket}:#{ip}"
  end
end
