require "base64"
require "json"

module Zipfelkasse::MCP
  PROTOCOL_VERSION = "2026-07-28"

  CODE_PARSE_ERROR         = -32700
  CODE_INVALID_REQUEST     = -32600
  CODE_METHOD_NOT_FOUND    = -32601
  CODE_INVALID_PARAMS      = -32602
  CODE_FORBIDDEN           = -32000
  CODE_HEADER_MISMATCH     = -32020
  CODE_UNSUPPORTED_VERSION = -32022

  META_PROTOCOL_VERSION = "io.modelcontextprotocol/protocolVersion"
  META_SERVER_INFO      = "io.modelcontextprotocol/serverInfo"

  LIST_TTL = 1.hour

  class RPCError < Exception
    getter status : Int32
    getter code : Int32
    getter id : String?
    getter data : {supported: Array(String), requested: String?}?

    def initialize(@status, @code, message : String, @id = nil, @data = nil)
      super(message)
    end

    def self.invalid_request(message : String, id : String? = nil) : RPCError
      new(400, CODE_INVALID_REQUEST, message, id)
    end

    def self.invalid_params(message : String, id : String?) : RPCError
      new(400, CODE_INVALID_PARAMS, message, id)
    end

    def self.header_mismatch(message : String, id : String?) : RPCError
      new(400, CODE_HEADER_MISMATCH, "Header mismatch: #{message}", id)
    end

    def self.forbidden(message : String) : RPCError
      new(403, CODE_FORBIDDEN, message)
    end

    def self.unsupported(version : String?, id : String?) : RPCError
      new(400, CODE_UNSUPPORTED_VERSION, "Unsupported protocol version.", id, {supported: [PROTOCOL_VERSION], requested: version})
    end
  end

  module RawJSON
    def self.from_json(pull : JSON::PullParser) : String
      pull.read_raw
    end
  end

  # A missing id makes a message a notification, "id":null does not.
  struct Message
    include JSON::Serializable

    getter jsonrpc = ""
    getter method = ""
    @[JSON::Field(converter: Zipfelkasse::MCP::RawJSON, presence: true)]
    @id : String? = nil
    @[JSON::Field(ignore: true)]
    @id_present = false
    @[JSON::Field(converter: Zipfelkasse::MCP::RawJSON)]
    getter params : String? = nil
    @[JSON::Field(presence: true)]
    @result : JSON::Any? = nil
    @[JSON::Field(ignore: true)]
    @result_present = false
    @[JSON::Field(presence: true)]
    @error : JSON::Any? = nil
    @[JSON::Field(ignore: true)]
    @error_present = false

    def id : String?
      @id || ("null" if @id_present)
    end

    def answer? : Bool
      @result_present || @error_present
    end
  end

  struct Params
    include JSON::Serializable

    @[JSON::Field(key: "_meta")]
    getter meta : Hash(String, JSON::Any)? = nil
    getter name : String?
    @[JSON::Field(converter: Zipfelkasse::MCP::RawJSON)]
    getter arguments : String? = nil

    def initialize
    end
  end

  def self.reason(ex : JSON::Error) : String
    detail = ex.message.to_s.lines.first? || ""
    ex.is_a?(JSON::SerializableError) && (field = ex.attribute) ? "#{field}: #{detail}" : detail
  end

  def self.parse_message(body : String) : Message
    pull = JSON::PullParser.new(body)
    message = Message.new(pull)
    pull.raise "Unexpected data after the message" unless pull.kind.eof?
    message
  rescue ex : JSON::Error
    raise RPCError.new(400, CODE_PARSE_ERROR, "Invalid JSON: #{reason(ex)}")
  end

  def self.parse_params(raw : String, id : String?) : Params
    Params.from_json(raw)
  rescue ex : JSON::Error
    raise RPCError.invalid_params("Invalid params: #{reason(ex)}", id)
  end

  def self.check_headers(headers : HTTP::Headers, method : String, tool : String?, id : String?) : Nil
    checks = [{"MCP-Protocol-Version", PROTOCOL_VERSION, "_meta"}, {"Mcp-Method", method, "method"}]
    checks << {"Mcp-Name", tool.to_s, "params.name"} if method == "tools/call"
    checks.each do |name, expected, source|
      actual = headers[name]?.try(&.strip).presence || raise RPCError.header_mismatch("header #{name} is missing.", id)
      if name == "Mcp-Name"
        actual = decode_header_value(actual) || raise RPCError.header_mismatch("#{name} is not valid Base64.", id)
      end
      unless actual == expected
        raise RPCError.header_mismatch("#{name} #{actual.inspect} does not match #{source} #{expected.inspect}.", id)
      end
    end
  end

  def self.decode_header_value(value : String) : String?
    prefix, suffix = "=?base64?", "?="
    return value unless value.starts_with?(prefix) && value.ends_with?(suffix) && value.bytesize >= prefix.bytesize + suffix.bytesize
    encoded = value.byte_slice(prefix.bytesize, value.bytesize - prefix.bytesize - suffix.bytesize)
    return unless encoded.matches?(/\A[A-Za-z0-9+\/]*={0,2}\z/) && (encoded.ends_with?('=') ? encoded.bytesize % 4 == 0 : encoded.bytesize % 4 != 1)
    String.new(Base64.decode(encoded))
  rescue Base64::Error
    nil
  end

  record Request, id : String, method : String, params : Params

  # Nil for notifications and answers of the client, which get no reply.
  def self.parse_request(body : String, headers : HTTP::Headers) : Request?
    raise RPCError.invalid_request("JSON-RPC batches are not supported.") if body.lstrip.starts_with?('[')
    message = parse_message(body)
    id = message.id
    if message.method.empty?
      raise RPCError.invalid_request("Field method is missing.", id) unless message.answer?
      return
    end
    raise RPCError.invalid_request(%(jsonrpc must be "2.0".), id) unless message.jsonrpc == "2.0"
    params = message.params.try { |raw| parse_params(raw, id) } || Params.new
    return unless id
    version = params.meta.try(&.[META_PROTOCOL_VERSION]?).try do |value|
      value.as_s?.presence || raise RPCError.invalid_params("_meta.#{META_PROTOCOL_VERSION} must be a non-empty string.", id)
    end
    raise RPCError.unsupported(version, id) unless version == PROTOCOL_VERSION
    check_headers(headers, message.method, params.name, id)
    Request.new(id, message.method, params)
  end

  SERVER_INFO  = {name: "zipfelkasse", title: "Zipfelkasse – shared expenses", version: SERVER_VERSION}
  CAPABILITIES = {tools: {listChanged: false}}

  class Server
    private def handle_post(env : HTTP::Server::Context, log : Hash(Symbol, String)) : Nil
      request = env.request
      unless request.headers["Content-Type"]?.try(&.partition(';')[0].strip.downcase) == "application/json"
        raise RPCError.new(415, CODE_INVALID_REQUEST, "Content-Type must be application/json.")
      end
      body = begin
        env.params.raw_body
      rescue Kemal::Exceptions::PayloadTooLarge
        raise RPCError.new(413, CODE_INVALID_REQUEST, "Message too large.")
      end
      request = MCP.parse_request(body, request.headers) || return accepted(env)
      log[:method] = request.method
      result = dispatch(request, log).merge(resultType: "complete", _meta: {META_SERVER_INFO => SERVER_INFO})
      reply(env, 200, request.id) { |json| json.field("result", result) }
    end

    # Closing the response keeps Kemal's error handlers from replacing the body of a 400, 404 or 413.
    private def reply(env : HTTP::Server::Context, status : Int32, id : String? = nil, & : JSON::Builder ->) : Nil
      response = env.response
      response.status_code = status
      response.content_type = "application/json"
      response.print(JSON.build do |json|
        json.object do
          json.field "jsonrpc", "2.0"
          json.field("id") { json.raw(id) } if id
          yield json
        end
      end)
      response.close
    end

    private def accepted(env : HTTP::Server::Context) : Nil
      env.response.status_code = 202
      env.response.headers.delete("Content-Type")
      env.response.close
    end

    private def reply_error(env : HTTP::Server::Context, error : RPCError) : Nil
      reply(env, error.status, error.id) do |json|
        json.field "error" do
          json.object do
            json.field "code", error.code
            json.field "message", error.message
            json.field "data", error.data if error.data
          end
        end
      end
    end

    private def dispatch(request : Request, log : Hash(Symbol, String))
      case request.method
      when "server/discover"
        {supportedVersions: [PROTOCOL_VERSION], capabilities: CAPABILITIES, instructions: instructions,
         ttlMs: discover_ttl.total_milliseconds.to_i64, cacheScope: "public"}
      when "ping"
        NamedTuple.new
      when "tools/list"
        {tools: @tools.values.map(&.definition), ttlMs: LIST_TTL.total_milliseconds.to_i64, cacheScope: "public"}
      when "tools/call"
        name = request.params.name.to_s
        raise RPCError.new(200, CODE_INVALID_PARAMS, "Unknown tool: #{name}", request.id) unless @tools.has_key?(name)
        log[:tool] = name
        text, error = run_tool(name, request.params.arguments)
        log[:tool_error] = text if error
        {content: [{type: "text", text: text}], isError: error}
      else
        raise RPCError.new(404, CODE_METHOD_NOT_FOUND, "Unknown method: #{request.method}", request.id)
      end
    end

    # Only text, no structuredContent (and so no outputSchema): Claude.ai passes only the text to the model, and a copy
    # of the JSON in both would double the size.
    def run_tool(name : String, arguments : String?) : {String, Bool}
      {@tools[name].run.call(arguments), false}
    rescue ex : Domain::ValidationError
      {ex.message.to_s, true}
    rescue ex
      Log.error(exception: ex, &.emit("mcp: tool failed", tool: name))
      {"Internal error while running the tool (details in the server log).", true}
    end
  end
end
