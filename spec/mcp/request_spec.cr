require "../spec_helper"

private def parse(body : String, headers = {} of String => String) : {MCP::Request, MCP::RequestInfo}
  info = MCP::RequestInfo.new
  request = MCP.parse_request(body, HTTP::Headers.new.tap { |h| headers.each { |k, v| h[k] = v } }, info)
  {request, info}
end

private def refusal(body : String, headers = {} of String => String) : MCP::RPCError
  parse(body, headers)
  raise "expected an error"
rescue ex : MCP::RPCError
  ex
end

describe "MCP.parse_request" do
  it "treats a request without _meta as legacy and takes the version from the header" do
    request, info = parse(%({"jsonrpc":"2.0","id":1,"method":"tools/list"}), {"MCP-Protocol-Version" => "2025-06-18"})
    {request.id, request.method, request.version, request.modern, request.reply}.should eq({"1", "tools/list", "2025-06-18", false, true})
    {info.method, info.version}.should eq({"tools/list", "2025-06-18"})
    parse(%({"jsonrpc":"2.0","id":1,"method":"tools/list"}))[0].version.should eq MCP::LEGACY_DEFAULT
  end

  it "negotiates the version of initialize" do
    parse(%({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}))[0].version.should eq "2025-06-18"
    parse(%({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999"}}))[0].version.should eq "2025-11-25"
    parse(%({"jsonrpc":"2.0","id":1,"method":"initialize"}))[0].version.should eq "2025-11-25"
  end

  it "reads the version of a modern request from _meta and checks the headers against it" do
    meta = %("_meta":{"#{MCP::META_PROTOCOL_VERSION}":"2026-07-28"})
    headers = {"MCP-Protocol-Version" => "2026-07-28", "Mcp-Method" => "tools/list"}
    request, _ = parse(%({"jsonrpc":"2.0","id":"a","method":"tools/list","params":{#{meta}}}), headers)
    {request.id, request.modern, request.version}.should eq({"\"a\"", true, "2026-07-28"})

    error = refusal(%({"jsonrpc":"2.0","id":"a","method":"tools/list","params":{#{meta}}}), headers.merge({"Mcp-Method" => "ping"}))
    {error.status, error.code, error.id}.should eq({400, MCP::CODE_HEADER_MISMATCH, "\"a\""})
    error.message.should eq %(Header mismatch: Mcp-Method "ping" does not match method "tools/list".)
  end

  it "does not reply to notifications and answers of the client" do
    parse(%({"jsonrpc":"2.0","method":"notifications/initialized"}), {"MCP-Protocol-Version" => "2025-06-18"})[0].reply.should be_false
    parse(%({"jsonrpc":"2.0","id":1,"result":{}}))[0].reply.should be_false
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
    }.each do |body, (code, id)|
      it "is refused with status 400 and code #{code}: #{body.inspect}" do
        error = refusal(body)
        {error.status, error.code, error.id}.should eq({400, code, id})
      end
    end

    it "is refused when its version is not supported" do
      error = refusal(%({"jsonrpc":"2.0","id":3,"method":"ping"}), {"MCP-Protocol-Version" => "1999-01-01"})
      {error.status, error.code, error.id}.should eq({400, MCP::CODE_UNSUPPORTED_VERSION, "3"})
    end

    {
      %({"jsonrpc":"2.0","id":1,"method":5})                                           => "Invalid JSON: method must be a string.",
      %("ping")                                                                        => "Invalid JSON: the message must be an object.",
      "null"                                                                           => "Field method is missing.",
      %({"jsonrpc":"2.0","id":7,"Method":"ping"})                                      => "Field method is missing.",
      %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":5}})            => "Invalid params: name must be a string.",
      %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":"x"})                   => "Invalid params: params must be an object.",
      %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"_meta":[]}})          => "Invalid params: _meta must be an object.",
      %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}) => "Invalid params: protocolVersion must be a string.",
    }.each do |body, message|
      it "is explained with #{message.inspect}: #{body.inspect}" do
        refusal(body).message.should eq message
      end
    end
  end

  it "trims the whitespace around header values" do
    request, _ = parse(%({"jsonrpc":"2.0","id":1,"method":"tools/list"}), {"MCP-Protocol-Version" => " 2025-06-18 "})
    request.version.should eq "2025-06-18"
    MCP.header(HTTP::Headers{"Mcp-Method" => "\ttools/call "}, "Mcp-Method").should eq "tools/call"
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
