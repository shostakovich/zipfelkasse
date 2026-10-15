defmodule ZipfelkasseWeb.MCPPlug do
  @moduledoc """
  The MCP endpoint at /mcp/<secret>, outside the web app: no session, no CSRF token, no person.
  Checked in this order: the secret, compared in constant time (a wrong one, or none configured,
  is a plain 404 for every method); POST only (405); the client address in MCP_ALLOWED_CIDRS
  (403); no Origin header, so no browser (403); JSON (415); at most 1 MiB (413). Every call is
  logged, a tool's refusal with its message, never the secret.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias Zipfelkasse.{MCP, Network, OrderedJSON}
  alias Zipfelkasse.MCP.{Access, Tools}

  @max_body 1_048_576
  @max_logged_refusal 300

  @doc "The largest request body in bytes, also for the web app."
  def max_body, do: @max_body

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    config = Application.fetch_env!(:zipfelkasse, :mcp)

    ip =
      Access.client_ip(
        conn.remote_ip,
        get_req_header(conn, "x-forwarded-for"),
        List.first(get_req_header(conn, "x-real-ip")),
        config[:trusted_proxies]
      )

    cond do
      not secret?(conn.request_path, config[:secret]) ->
        Logger.warning(
          "MCP: wrong secret, ip=#{Access.format(ip)} remote=#{Access.format(conn.remote_ip)}"
        )

        plain(conn, 404, "Not Found\n")

      conn.method != "POST" ->
        conn |> put_resp_header("allow", "POST") |> plain(405, "Method Not Allowed\n")

      true ->
        started = System.monotonic_time(:millisecond)
        {conn, call} = serve(conn, config, ip)
        duration = System.monotonic_time(:millisecond) - started

        fields =
          [ip: Access.format(ip), method: inspected(call[:method]), tool: inspected(call[:tool])] ++
            [
              status: conn.status,
              duration: "#{duration}ms",
              tool_error: inspected(call[:refusal])
            ]

        Logger.info(
          "MCP " <> Enum.join(for({key, value} <- fields, value, do: "#{key}=#{value}"), " ")
        )

        conn
    end
  end

  defp inspected(nil), do: nil
  defp inspected(value), do: inspect(value)

  defp secret?(_path, nil), do: false

  defp secret?("/mcp/" <> given, secret) do
    Plug.Crypto.secure_compare(URI.decode(given), secret)
  rescue
    ArgumentError -> false
  end

  defp secret?(_path, _secret), do: false

  defp serve(conn, config, ip) do
    origin = conn |> get_req_header("origin") |> Enum.find("", &(&1 != ""))

    cond do
      is_nil(ip) or not Network.member?(ip, config[:allowed_cidrs]) ->
        Logger.warning(
          "MCP: IP not allowed, ip=#{Access.format(ip)} remote=#{Access.format(conn.remote_ip)} " <>
            "x_forwarded_for=#{inspect(get_req_header(conn, "x-forwarded-for"))} " <>
            "x_real_ip=#{inspect(get_req_header(conn, "x-real-ip"))}"
        )

        {error(conn, 403, -32_000, "Access from this address is not allowed."), []}

      origin != "" ->
        Logger.warning(
          "MCP: Origin header rejected, ip=#{Access.format(ip)} origin=#{inspect(origin)}"
        )

        {error(conn, 403, -32_000, "Access from a browser is not allowed."), []}

      not json?(conn) ->
        {error(conn, 415, -32_600, "Content-Type must be application/json."), []}

      true ->
        read(conn)
    end
  end

  defp json?(conn) do
    case get_req_header(conn, "content-type") do
      [type | _] ->
        type |> String.split(";") |> hd() |> String.trim() |> String.downcase() ==
          "application/json"

      [] ->
        false
    end
  end

  defp read(conn) do
    case read_body(conn, length: @max_body + 1) do
      {:ok, body, conn} when byte_size(body) <= @max_body -> handle(conn, body)
      {_more_or_error, _body, conn} -> {error(conn, 413, -32_600, "Message too large."), []}
      {:error, _reason} -> {error(conn, 413, -32_600, "Message too large."), []}
    end
  end

  defp handle(conn, body) do
    case MCP.parse(body, conn.req_headers) do
      {:ok, nil} ->
        {send_resp(conn, 202, ""), []}

      {:error, error} ->
        {error_reply(conn, error), []}

      {:ok, request} ->
        tool = if request.method == "tools/call", do: request.params["name"]
        tool = if tool in Tools.names(), do: tool

        {conn, refusal} =
          case MCP.dispatch(request) do
            {:ok, result} -> {reply(conn, 200, request.id, %{result: result}), refusal(result)}
            {:error, error} -> {error_reply(conn, error), nil}
          end

        {conn, method: request.method, tool: tool, refusal: refusal}
    end
  end

  defp refusal(%{isError: true, content: [%{text: text} | _rest]}) do
    if String.length(text) > @max_logged_refusal,
      do: String.slice(text, 0, @max_logged_refusal) <> "…",
      else: text
  end

  defp refusal(_result), do: nil

  defp error_reply(conn, error),
    do: reply(conn, error.status, error.id, %{error: error_body(error)})

  defp error(conn, status, code, message),
    do: reply(conn, status, nil, %{error: error_body(%MCP.Error{code: code, message: message})})

  defp error_body(error) do
    body = %{code: error.code, message: error.message}
    if error.data, do: Map.put(body, :data, error.data), else: body
  end

  defp reply(conn, status, id, payload) do
    body =
      case id do
        {:id, value} -> Map.merge(payload, %{jsonrpc: "2.0", id: value})
        nil -> Map.put(payload, :jsonrpc, "2.0")
      end

    conn
    |> put_resp_content_type("application/json", nil)
    |> send_resp(status, OrderedJSON.encode!(body))
  end

  defp plain(conn, status, text) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, text)
  end
end
