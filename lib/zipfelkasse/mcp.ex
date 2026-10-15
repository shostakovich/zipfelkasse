defmodule Zipfelkasse.MCP do
  @moduledoc """
  The MCP server for AI assistants: JSON-RPC in protocol version 2026-07-28 only, stateless (no
  handshake, no session, no batches). Each request names the version in `_meta`, and the
  headers MCP-Protocol-Version, Mcp-Method and, for tools/call, Mcp-Name repeat the body.
  Methods: server/discover, ping, tools/list and tools/call; notifications and answers of the
  client get no reply. See `Zipfelkasse.MCP.Tools` for the tools.
  """

  require Logger

  alias Zipfelkasse.{Activities, Expenses, LocalTime}
  alias Zipfelkasse.MCP.Tools

  @version "2026-07-28"
  @meta_version "io.modelcontextprotocol/protocolVersion"
  @meta_server "io.modelcontextprotocol/serverInfo"
  @list_ttl :timer.hours(1)

  @external_resource Path.join(__DIR__, "mcp/texts/instructions.txt")
  @instructions __DIR__
                |> Path.join("mcp/texts/instructions.txt")
                |> File.read!()
                |> String.trim_trailing()

  defmodule Error do
    @moduledoc "A JSON-RPC error with its HTTP status; `id` is `{:id, value}` if the request had one."
    defexception [:status, :code, :message, :id, :data]
  end

  @type id :: {:id, term()} | nil
  @type request :: %{id: {:id, term()}, method: String.t(), params: map()}

  @doc "The protocol version."
  def version, do: @version

  @doc """
  Reads a message (the body) with the request `headers` (`{name, value}`, names in lower case).
  Nil for a notification or an answer of the client, which get no reply.
  """
  @spec parse(binary(), [{String.t(), String.t()}]) ::
          {:ok, request() | nil} | {:error, Exception.t()}
  def parse(body, headers) do
    with :ok <- no_batch(body),
         {:ok, message} <- decode(body),
         id = if(Map.has_key?(message, "id"), do: {:id, message["id"]}),
         {:ok, method} <- method(message, id) do
      if method, do: request(id, method, message["params"], headers), else: {:ok, nil}
    end
  end

  defp request(id, method, params, headers) do
    with {:ok, params} <- params(params, id) do
      if id, do: checked_request(id, method, params, headers), else: {:ok, nil}
    end
  end

  defp checked_request(id, method, params, headers) do
    with :ok <- check_version(params, id),
         :ok <- check_headers(headers, method, params["name"], id),
         do: {:ok, %{id: id, method: method, params: params}}
  end

  defp no_batch(body) do
    if String.starts_with?(String.trim_leading(body), "["),
      do: error(400, -32_600, "JSON-RPC batches are not supported."),
      else: :ok
  end

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, %{} = message} -> check_fields(message)
      {:ok, _other} -> error(400, -32_700, "Invalid JSON: expected an object")
      {:error, reason} -> error(400, -32_700, "Invalid JSON: #{reason(reason)}")
    end
  end

  defp check_fields(message) do
    case Enum.find(["jsonrpc", "method"], &(not (is_nil(message[&1]) or is_binary(message[&1])))) do
      nil -> {:ok, message}
      field -> error(400, -32_700, "Invalid JSON: #{field}: expected a string")
    end
  end

  defp reason({:unexpected_end, _offset}), do: "unexpected end of input"
  defp reason({:invalid_byte, offset, byte}), do: "invalid byte #{inspect(<<byte>>)} at #{offset}"

  defp reason({:unexpected_sequence, offset, bytes}),
    do: "unexpected #{inspect(bytes)} at #{offset}"

  defp reason(other), do: inspect(other)

  # An answer of the client has no method but a result or an error.
  defp method(message, id) do
    case message["method"] do
      method when method not in [nil, ""] ->
        if message["jsonrpc"] == "2.0",
          do: {:ok, method},
          else: error(400, -32_600, ~s(jsonrpc must be "2.0".), id)

      _none ->
        if Map.has_key?(message, "result") or Map.has_key?(message, "error"),
          do: {:ok, nil},
          else: error(400, -32_600, "Field method is missing.", id)
    end
  end

  defp params(nil, _id), do: {:ok, %{}}

  defp params(%{} = params, id) do
    cond do
      not (is_nil(params["_meta"]) or is_map(params["_meta"])) ->
        error(400, -32_602, "Invalid params: _meta: expected an object", id)

      not (is_nil(params["name"]) or is_binary(params["name"])) ->
        error(400, -32_602, "Invalid params: name: expected a string", id)

      true ->
        {:ok, params}
    end
  end

  defp params(_params, id), do: error(400, -32_602, "Invalid params: expected an object", id)

  defp check_version(params, id) do
    case (params["_meta"] || %{})[@meta_version] do
      @version ->
        :ok

      version when version == "" or not (is_nil(version) or is_binary(version)) ->
        error(400, -32_602, "_meta.#{@meta_version} must be a non-empty string.", id)

      version ->
        {:error,
         %Error{
           status: 400,
           code: -32_022,
           message: "Unsupported protocol version.",
           id: id,
           data: %{supported: [@version], requested: version}
         }}
    end
  end

  defp check_headers(headers, method, tool, id) do
    checks = [{"MCP-Protocol-Version", @version, "_meta"}, {"Mcp-Method", method, "method"}]

    checks =
      if method == "tools/call",
        do: checks ++ [{"Mcp-Name", tool || "", "params.name"}],
        else: checks

    Enum.reduce_while(checks, :ok, fn {name, expected, source}, :ok ->
      case check_header(headers, name, expected, source) do
        :ok -> {:cont, :ok}
        {:mismatch, message} -> {:halt, error(400, -32_020, "Header mismatch: " <> message, id)}
      end
    end)
  end

  defp check_header(headers, name, expected, source) do
    value =
      case List.keyfind(headers, String.downcase(name), 0) do
        {_name, value} -> String.trim(value)
        nil -> ""
      end

    value = if name == "Mcp-Name" and value != "", do: decode_header_value(value), else: value

    cond do
      value == "" ->
        {:mismatch, "header #{name} is missing."}

      value == :invalid ->
        {:mismatch, "#{name} is not valid Base64."}

      value != expected ->
        {:mismatch, "#{name} #{inspect(value)} does not match #{source} #{inspect(expected)}."}

      true ->
        :ok
    end
  end

  @doc ~s(A header value, decoded if it is written as "=?base64?…?="; `:invalid` if that fails.)
  def decode_header_value("=?base64?" <> rest = value) when byte_size(rest) >= 2 do
    encoded = binary_part(rest, 0, byte_size(rest) - 2)

    cond do
      not String.ends_with?(rest, "?=") -> value
      not (encoded =~ ~r/\A[A-Za-z0-9+\/]*={0,2}\z/) -> :invalid
      String.ends_with?(encoded, "=") -> decode64(encoded, rem(byte_size(encoded), 4) == 0, true)
      true -> decode64(encoded, rem(byte_size(encoded), 4) != 1, false)
    end
  end

  def decode_header_value(value), do: value

  defp decode64(_encoded, false, _padding), do: :invalid

  defp decode64(encoded, true, padding) do
    case Base.decode64(encoded, padding: padding) do
      {:ok, decoded} -> decoded
      :error -> :invalid
    end
  end

  @doc "Answers a request: `{:ok, result}` or `{:error, %Error{}}`."
  def dispatch(%{method: "server/discover"}) do
    result(%{
      supportedVersions: [@version],
      capabilities: %{tools: %{listChanged: false}},
      instructions: instructions(),
      ttlMs: discover_ttl(),
      cacheScope: "public"
    })
  end

  def dispatch(%{method: "ping"}), do: result(%{})

  def dispatch(%{method: "tools/list"}),
    do: result(%{tools: Tools.list(), ttlMs: @list_ttl, cacheScope: "public"})

  def dispatch(%{method: "tools/call", id: id, params: params}) do
    name = params["name"] || ""

    case Tools.call(name, params["arguments"]) do
      :unknown -> error(200, -32_602, "Unknown tool: #{name}", id)
      {text, error?} -> result(%{content: [%{type: "text", text: text}], isError: error?})
    end
  end

  def dispatch(%{method: method, id: id}),
    do: error(404, -32_601, "Unknown method: #{method}", id)

  defp result(result) do
    server = %{
      name: "zipfelkasse",
      title: "Zipfelkasse – shared expenses",
      version: app_version()
    }

    {:ok, Map.merge(result, %{resultType: "complete", _meta: %{@meta_server => server}})}
  end

  defp app_version, do: :zipfelkasse |> Application.spec(:vsn) |> to_string()

  defp error(status, code, message, id \\ nil),
    do: {:error, %Error{status: status, code: code, message: message, id: id}}

  @doc ~s(The line with today and the time zone, as the instructions and the schema tool start.)
  def today_line(opts \\ []) do
    today = Keyword.get_lazy(opts, :today, &LocalTime.today/0)

    "Today is #{today} (#{Calendar.strftime(today, "%A")}), server time zone #{zone()}. " <>
      ~s(Resolve relative periods such as "last month" from this date.)
  end

  defp zone do
    case System.get_env("TZ", "") do
      "" -> "Local"
      zone -> zone
    end
  end

  @doc "The instructions of server/discover: how to use the tools, today and a data overview."
  def instructions do
    @instructions <> "\n" <> today_line() <> "\n" <> overview()
  rescue
    error ->
      Logger.error("MCP: the data overview failed: " <> Exception.message(error))
      @instructions <> "\n" <> today_line()
  end

  defp overview do
    o = Expenses.overview()
    actions = Activities.list_actions()

    data =
      if o.first_date do
        percent = if o.expenses > 0, do: o.without_category * 100 / o.expenses, else: 0.0

        "#{o.expenses} expenses and #{o.reimbursements} reimbursements dated #{o.first_date} to " <>
          "#{o.last_date}. #{o.without_category} of the expenses " <>
          "(#{:erlang.float_to_binary(percent / 1, decimals: 1)}%) have no category."
      else
        "there are no expenses yet."
      end

    "Data overview: " <>
      data <>
      if(actions == [],
        do: "",
        else: " Values of activities.action: #{Enum.join(actions, ", ")}."
      )
  end

  @doc "How long server/discover may be cached: an hour, at most until local midnight, as it holds today."
  def discover_ttl(now \\ DateTime.utc_now()) do
    tomorrow = now |> LocalTime.date() |> Date.add(1) |> NaiveDateTime.new!(~T[00:00:00])
    min(@list_ttl, DateTime.diff(LocalTime.to_utc(tomorrow), now, :millisecond))
  end
end
