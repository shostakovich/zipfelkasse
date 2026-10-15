defmodule Zipfelkasse.MCPTest do
  use ExUnit.Case, async: true

  alias Zipfelkasse.MCP
  alias Zipfelkasse.MCP.Output

  @meta ~s("_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"})
  @headers [{"mcp-protocol-version", "2026-07-28"}, {"mcp-method", "tools/list"}]

  defp refusal(body, headers \\ []) do
    assert {:error, %MCP.Error{} = error} = MCP.parse(body, headers)
    error
  end

  test "reads a request whose headers match _meta and the body" do
    assert {:ok, %{id: {:id, "a"}, method: "tools/list"}} =
             MCP.parse(
               ~s({"jsonrpc":"2.0","id":"a","method":"tools/list","params":{#{@meta}}}),
               @headers
             )
  end

  test "refuses a header that does not match the body" do
    error =
      refusal(~s({"jsonrpc":"2.0","id":"a","method":"tools/list","params":{#{@meta}}}), [
        {"mcp-protocol-version", "2026-07-28"},
        {"mcp-method", "ping"}
      ])

    assert {error.status, error.code, error.id} == {400, -32_020, {:id, "a"}}

    assert error.message ==
             ~s(Header mismatch: Mcp-Method "ping" does not match method "tools/list".)
  end

  test "refuses requests without the protocol version in _meta or with another one" do
    for body <- [
          ~s({"jsonrpc":"2.0","id":3,"method":"ping"}),
          ~s({"jsonrpc":"2.0","id":3,"method":"ping","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2025-06-18"}}})
        ] do
      error = refusal(body)
      assert {error.status, error.code, error.id} == {400, -32_022, {:id, 3}}
    end
  end

  test "does not reply to notifications and answers of the client" do
    assert MCP.parse(~s({"jsonrpc":"2.0","method":"notifications/cancelled"}), []) == {:ok, nil}
    assert MCP.parse(~s({"jsonrpc":"2.0","id":1,"result":{}}), []) == {:ok, nil}
  end

  for {body, code, id} <- [
        {~s([{"jsonrpc":"2.0","id":1,"method":"ping"}]), -32_600, nil},
        {~s({"jsonrpc":"1.0","id":3,"method":"ping"}), -32_600, {:id, 3}},
        {~s({"jsonrpc":"2.0","id":3}), -32_600, {:id, 3}},
        {~s({"jsonrpc":"2.0","id":3,"method":"ping","params":[]}), -32_602, {:id, 3}},
        {~s({broken), -32_700, nil},
        {~s({"jsonrpc":"2.0","id":1,"method":"ping"} x), -32_700, nil},
        {"", -32_700, nil},
        {"null", -32_700, nil}
      ] do
    test "refuses #{inspect(body)} with 400 and #{code}" do
      error = refusal(unquote(body))

      assert {error.status, error.code, error.id} ==
               {400, unquote(code), unquote(Macro.escape(id))}
    end
  end

  for {body, prefix} <- [
        {~s({"jsonrpc":"2.0","id":1,"method":5}), "Invalid JSON: method: "},
        {~s({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":5}}),
         "Invalid params: name: "},
        {~s({"jsonrpc":"2.0","id":1,"method":"tools/call","params":"x"}), "Invalid params: "}
      ] do
    test "names the offending field: #{inspect(body)}" do
      assert String.starts_with?(refusal(unquote(body)).message, unquote(prefix))
    end
  end

  for {value, decoded} <- [
        {"balances", "balances"},
        {"=?base64?SGVsbG8sIOS4lueVjA==?=", "Hello, 世界"},
        {"=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=", "=?base64?literal?="},
        {"=?base64?SGVsbG8?=", "Hello"},
        {"=?base64?!!!?=", :invalid},
        {"=?base64?=", "=?base64?="}
      ] do
    test "decodes the header value #{inspect(value)}" do
      assert MCP.decode_header_value(unquote(value)) == unquote(decoded)
    end
  end

  test "formats euros with a dot and without grouping" do
    assert Output.eur(-300_000) == "-3000.00"
  end

  for {text, decimals, minor} <- [
        {"23.4", 2, 2340},
        {"23.40", 2, 2340},
        {"23", 2, 2300},
        {"1.000", 2, 100},
        {"0.5", 2, 50},
        {" 7 ", 2, 700},
        {"5.", 2, 500},
        {"1200.00", 0, 1200}
      ] do
    test "reads the amount #{inspect(text)} with #{decimals} decimals as #{minor}" do
      assert Zipfelkasse.Money.parse_decimal(unquote(text), unquote(decimals)) ==
               {:ok, unquote(minor)}
    end
  end

  for {text, decimals} <- [
        {"1.234", 2},
        {"1.5", 0},
        {"1,5", 2},
        {"1.000,00", 2},
        {"-1", 2},
        {"+1", 2},
        {".5", 2},
        {"1e3", 2},
        {"", 2},
        {"1.2.3", 2},
        {"1 000", 2},
        {"1234567890123456", 2}
      ] do
    test "refuses the amount #{inspect(text)} with #{decimals} decimals" do
      assert Zipfelkasse.Money.parse_decimal(unquote(text), unquote(decimals)) == :error
    end
  end
end
