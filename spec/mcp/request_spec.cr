require "../spec_helper"

private META = %("_meta":{"#{MCP::META_PROTOCOL_VERSION}":"2026-07-28"})

private def parse(body : String, headers = {"MCP-Protocol-Version" => "2026-07-28", "Mcp-Method" => "tools/list"}) : MCP::Request?
  MCP.parse_request(body, HTTP::Headers.new.tap { |h| headers.each { |k, v| h[k] = v } })
end

private def refusal(body : String, headers = {} of String => String) : MCP::RPCError
  expect_raises(MCP::RPCError) { parse(body, headers) }
end

describe "MCP.parse_request" do
  it "reads a request whose headers match _meta and the body" do
    request = parse(%({"jsonrpc":"2.0","id":"a","method":"tools/list","params":{#{META}}})).not_nil!
    {request.id, request.method}.should eq({"\"a\"", "tools/list"})
  end

  it "trims the whitespace around header values" do
    parse(%({"jsonrpc":"2.0","id":1,"method":"tools/list","params":{#{META}}}),
      {"MCP-Protocol-Version" => " 2026-07-28 ", "Mcp-Method" => "\ttools/list "}).should_not be_nil
  end

  it "refuses a header that does not match the body" do
    error = refusal(%({"jsonrpc":"2.0","id":"a","method":"tools/list","params":{#{META}}}),
      {"MCP-Protocol-Version" => "2026-07-28", "Mcp-Method" => "ping"})
    {error.status, error.code, error.id}.should eq({400, MCP::CODE_HEADER_MISMATCH, "\"a\""})
    error.message.should eq %(Header mismatch: Mcp-Method "ping" does not match method "tools/list".)
  end

  it "refuses requests without the protocol version in _meta or with another one" do
    [%({"jsonrpc":"2.0","id":3,"method":"ping"}),
     %({"jsonrpc":"2.0","id":3,"method":"ping","params":{"_meta":{"#{MCP::META_PROTOCOL_VERSION}":"2025-06-18"}}})].each do |body|
      error = refusal(body)
      {error.status, error.code, error.id}.should eq({400, MCP::CODE_UNSUPPORTED_VERSION, "3"})
    end
  end

  it "does not reply to notifications and answers of the client" do
    parse(%({"jsonrpc":"2.0","method":"notifications/cancelled"}), {} of String => String).should be_nil
    parse(%({"jsonrpc":"2.0","id":1,"result":{}}), {} of String => String).should be_nil
  end

  describe "a message that is not a request" do
    {
      %([{"jsonrpc":"2.0","id":1,"method":"ping"}])           => {MCP::CODE_INVALID_REQUEST, nil},
      %({"jsonrpc":"1.0","id":3,"method":"ping"})             => {MCP::CODE_INVALID_REQUEST, "3"},
      %({"jsonrpc":"2.0","id":3})                             => {MCP::CODE_INVALID_REQUEST, "3"},
      %({"jsonrpc":"2.0","id":3,"method":"ping","params":[]}) => {MCP::CODE_INVALID_PARAMS, "3"},
      %({broken)                                              => {MCP::CODE_PARSE_ERROR, nil},
      %({"jsonrpc":"2.0","id":1,"method":"ping"} x)           => {MCP::CODE_PARSE_ERROR, nil},
      ""                                                      => {MCP::CODE_PARSE_ERROR, nil},
      "null"                                                  => {MCP::CODE_PARSE_ERROR, nil},
    }.each do |body, (code, id)|
      it "is refused with status 400 and code #{code}: #{body.inspect}" do
        error = refusal(body)
        {error.status, error.code, error.id}.should eq({400, code, id})
      end
    end

    {
      %({"jsonrpc":"2.0","id":7,"Method":"ping"})                                                              => "Field method is missing.",
      %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"_meta":{"#{MCP::META_PROTOCOL_VERSION}":7}}}) => "_meta.io.modelcontextprotocol/protocolVersion must be a non-empty string.",
    }.each do |body, message|
      it "is explained with #{message.inspect}: #{body.inspect}" do
        refusal(body).message.should eq message
      end
    end

    {
      %({"jsonrpc":"2.0","id":1,"method":5})                                => "Invalid JSON: method: ",
      %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":5}}) => "Invalid params: name: ",
      %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":"x"})        => "Invalid params: ",
    }.each do |body, prefix|
      it "names the offending field after #{prefix.inspect}: #{body.inspect}" do
        refusal(body).message.to_s.should start_with prefix
      end
    end
  end
end

describe "MCP.decode_header_value" do
  {
    "balances"                            => "balances",
    "=?base64?SGVsbG8sIOS4lueVjA==?="     => "Hello, 世界",
    "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=" => "=?base64?literal?=",
    "=?base64?SGVsbG8?="                  => "Hello",
    "=?base64?!!!?="                      => nil,
    "=?base64?="                          => "=?base64?=",
  }.each do |value, decoded|
    it "decodes #{value.inspect} as #{decoded.inspect}" do
      MCP.decode_header_value(value).should eq decoded
    end
  end
end
