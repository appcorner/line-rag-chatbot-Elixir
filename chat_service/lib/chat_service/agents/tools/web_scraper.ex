defmodule ChatService.Agents.Tools.WebScraper do
  @moduledoc false

  @behaviour ChatService.Agents.Tool

  require Logger

  @impl true
  def name, do: "scrape_website"

  @impl true
  def definition do
    %{
      name: name(),
      description: "ดึงเนื้อหาจากเว็บไซต์ (มีการป้องกัน SSRF)",
      parameters: %{
        type: "object",
        properties: %{
          url: %{
            type: "string",
            description: "URL ของเว็บไซต์ที่ต้องการดึงข้อมูล"
          }
        },
        required: ["url"]
      }
    }
  end

  @impl true
  def enabled?, do: true

  @impl true
  def execute(%{"url" => url}) when is_binary(url) do
    execute(%{url: url})
  end

  def execute(%{url: url}) when is_binary(url) do
    Logger.info("[WebScraper] Scraping URL: #{url}")

    with :ok <- validate_url(url),
         :ok <- check_ssrf(url),
         {:ok, content} <- fetch_url(url) do
      # Clean HTML and limit content
      clean_content =
        content
        |> strip_html_tags()
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
        |> String.slice(0, 3000)

      {:ok, clean_content}
    else
      {:error, reason} ->
        Logger.warning("[WebScraper] Blocked or failed: #{reason}")
        {:error, reason}
    end
  end

  def execute(_params) do
    {:error, "Missing required parameter: url"}
  end

  # URL validation
  defp validate_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        :ok

      %URI{scheme: nil} ->
        {:error, "Invalid URL: missing scheme (http/https)"}

      %URI{scheme: scheme} when scheme not in ["http", "https"] ->
        {:error, "Invalid URL scheme: only http and https are allowed"}

      %URI{host: nil} ->
        {:error, "Invalid URL: missing host"}

      _ ->
        {:error, "Invalid URL format"}
    end
  end

  # SSRF protection
  defp check_ssrf(url) do
    uri = URI.parse(url)
    host = uri.host

    cond do
      is_localhost?(host) ->
        {:error, "SSRF blocked: localhost access not allowed"}

      is_private_ip?(host) ->
        {:error, "SSRF blocked: private IP range not allowed"}

      is_metadata_service?(host) ->
        {:error, "SSRF blocked: metadata service access not allowed"}

      is_internal_hostname?(host) ->
        {:error, "SSRF blocked: internal hostname not allowed"}

      true ->
        # DNS resolution check
        check_resolved_ip(host)
    end
  end

  defp is_localhost?(host) do
    host in [
      "localhost",
      "127.0.0.1",
      "::1",
      "0.0.0.0",
      "[::1]",
      "0177.0.0.1",      # Octal
      "2130706433",      # Decimal
      "0x7f.0.0.1"       # Hex
    ] or String.ends_with?(host, ".localhost")
  end

  defp is_private_ip?(host) do
    case parse_ip(host) do
      {:ok, {10, _, _, _}} -> true
      {:ok, {172, b, _, _}} when b >= 16 and b <= 31 -> true
      {:ok, {192, 168, _, _}} -> true
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, _, _, _}} -> true
      _ -> false
    end
  end

  defp is_metadata_service?(host) do
    # AWS/GCP/Azure metadata service
    host in [
      "169.254.169.254",
      "metadata.google.internal",
      "metadata.goog"
    ] or
      case parse_ip(host) do
        {:ok, {169, 254, _, _}} -> true
        _ -> false
      end
  end

  defp is_internal_hostname?(host) do
    # Common internal hostnames
    internal_patterns = [
      ".internal",
      ".local",
      ".corp",
      ".lan",
      ".intranet",
      ".private"
    ]

    Enum.any?(internal_patterns, fn pattern ->
      String.ends_with?(host, pattern)
    end)
  end

  defp parse_ip(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> :not_ip
    end
  end

  defp check_resolved_ip(host) do
    case :inet.gethostbyname(String.to_charlist(host)) do
      {:ok, {:hostent, _, _, _, _, [ip | _]}} ->
        if is_private_ip_tuple?(ip) do
          {:error, "SSRF blocked: hostname resolves to private IP"}
        else
          :ok
        end

      {:error, reason} ->
        Logger.warning("[WebScraper] DNS resolution failed for #{host}: #{inspect(reason)}")
        # Allow if DNS fails (might be valid external host)
        :ok
    end
  end

  defp is_private_ip_tuple?({10, _, _, _}), do: true
  defp is_private_ip_tuple?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  defp is_private_ip_tuple?({192, 168, _, _}), do: true
  defp is_private_ip_tuple?({127, _, _, _}), do: true
  defp is_private_ip_tuple?({169, 254, _, _}), do: true
  defp is_private_ip_tuple?({0, _, _, _}), do: true
  defp is_private_ip_tuple?(_), do: false

  # Fetch URL content
  defp fetch_url(url) do
    headers = [
      {"user-agent", "ChatService-Bot/1.0"},
      {"accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"}
    ]

    request = Finch.build(:get, url, headers)

    case Finch.request(request, ChatService.Finch, receive_timeout: 15_000) do
      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Finch.Response{status: status}} ->
        {:error, "HTTP error: #{status}"}

      {:error, reason} ->
        {:error, "Request failed: #{inspect(reason)}"}
    end
  end

  # Strip HTML tags
  defp strip_html_tags(html) do
    html
    |> String.replace(~r/<script[^>]*>.*?<\/script>/is, "")
    |> String.replace(~r/<style[^>]*>.*?<\/style>/is, "")
    |> String.replace(~r/<[^>]+>/, " ")
    |> HtmlEntities.decode()
  rescue
    # If HtmlEntities is not available, just return stripped
    _ -> String.replace(html, ~r/<[^>]+>/, " ")
  end
end
