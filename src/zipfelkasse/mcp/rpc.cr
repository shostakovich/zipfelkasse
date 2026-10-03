require "base64"
require "json"

module Zipfelkasse::MCP
  # Modern = stateless with _meta per request, legacy = initialize handshake.
  MODERN_VERSIONS = ["2026-07-28"]
  LEGACY_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26"]
  ALL_VERSIONS    = MODERN_VERSIONS + LEGACY_VERSIONS

  # For requests without an MCP-Protocol-Version header (as the spec requires
  # for clients before 2025-06-18).
  LEGACY_DEFAULT = "2025-03-26"

  CODE_PARSE_ERROR         = -32700
  CODE_INVALID_REQUEST     = -32600
  CODE_METHOD_NOT_FOUND    = -32601
  CODE_INVALID_PARAMS      = -32602
  CODE_FORBIDDEN           = -32000 # implementation-specific: access denied
  CODE_HEADER_MISMATCH     = -32020
  CODE_UNSUPPORTED_VERSION = -32022

  META_PROTOCOL_VERSION = "io.modelcontextprotocol/protocolVersion"
  META_SERVER_INFO      = "io.modelcontextprotocol/serverInfo"

  LIST_TTL = 1.hour

  class RPCError < Exception
    getter status : Int32
    getter code : Int32
    getter id : String?
    getter data : {supported: Array(String), requested: String}?

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
      new(400, CODE_HEADER_MISMATCH, message, id)
    end

    def self.too_large : RPCError
      new(413, CODE_INVALID_REQUEST, "Message too large or incomplete.")
    end

    def self.unsupported(version : String, id : String?) : RPCError
      new(400, CODE_UNSUPPORTED_VERSION, "Unsupported protocol version.", id,
        {supported: ALL_VERSIONS, requested: version})
    end
  end

  module RawJSON
    def self.from_json(pull : JSON::PullParser) : String
      pull.read_raw
    end
  end

  # A JSON-RPC message; a missing id makes it a notification, "id":null does
  # not.
  struct Message
    include Decodable

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

    def initialize
    end

    def id : String?
      @id || ("null" if @id_present)
    end

    def answer? : Bool
      @result_present || @error_present
    end
  end

  struct Params
    include Decodable

    @[JSON::Field(key: "_meta")]
    getter meta : Hash(String, JSON::Any)? = nil
    getter name : String?
    @[JSON::Field(converter: Zipfelkasse::MCP::RawJSON)]
    getter arguments : String? = nil
    @[JSON::Field(key: "protocolVersion")]
    getter protocol_version : String?

    def initialize
    end
  end

  def self.parse_message(body : String) : Message
    pull = JSON::PullParser.new(body)
    message = pull.kind.null? ? (pull.read_null; Message.new) : Message.new(pull)
    raise JSON::ParseException.new("Unexpected data after the message", *pull.location) unless pull.kind.eof?
    message
  rescue ex : JSON::SerializableError
    detail = begin
      JSON.parse(body) # a syntax error inside a field is not a wrong type
      decode_error(Message, ex, "the message")
    rescue syntax : JSON::ParseException
      syntax.message
    end
    raise RPCError.new(400, CODE_PARSE_ERROR, "Invalid JSON: #{detail}")
  rescue ex : JSON::ParseException
    raise RPCError.new(400, CODE_PARSE_ERROR, "Invalid JSON: #{ex.message}")
  end

  def self.parse_params(raw : String, id : String?) : Params
    Params.from_json(raw)
  rescue ex : JSON::SerializableError
    raise RPCError.invalid_params("Invalid params: #{decode_error(Params, ex, "params")}", id)
  end

  def self.negotiate(requested : String?) : String
    requested && LEGACY_VERSIONS.includes?(requested) ? requested : LEGACY_VERSIONS.first
  end

  def self.header(headers : HTTP::Headers, name : String) : String
    headers.get?(name).try(&.first?).try(&.strip) || ""
  end

  def self.check_headers(headers : HTTP::Headers, method : String, name : String, version : String, id : String?) : Nil
    mismatch = ->(reason : String) { RPCError.header_mismatch("Header mismatch: #{reason}", id) }
    h = header(headers, "MCP-Protocol-Version")
    raise mismatch.call("header MCP-Protocol-Version is missing.") if h.empty?
    raise mismatch.call("MCP-Protocol-Version #{h.inspect} does not match _meta #{version.inspect}.") if h != version
    h = header(headers, "Mcp-Method")
    raise mismatch.call("header Mcp-Method is missing.") if h.empty?
    raise mismatch.call("Mcp-Method #{h.inspect} does not match method #{method.inspect}.") if h != method
    return unless method == "tools/call"
    h = header(headers, "Mcp-Name")
    raise mismatch.call("header Mcp-Name is missing.") if h.empty?
    value = decode_header_value(h) || raise mismatch.call("Mcp-Name is not valid Base64.")
    raise mismatch.call("Mcp-Name #{value.inspect} does not match params.name #{name.inspect}.") if value != name
  end

  def self.decode_header_value(v : String) : String?
    prefix, suffix = "=?base64?", "?="
    return v unless v.starts_with?(prefix) && v.ends_with?(suffix) && v.bytesize >= prefix.bytesize + suffix.bytesize
    enc = v.byte_slice(prefix.bytesize, v.bytesize - prefix.bytesize - suffix.bytesize)
    return unless enc.matches?(/\A[A-Za-z0-9+\/]*={0,2}\z/) && (enc.ends_with?('=') ? enc.bytesize % 4 == 0 : enc.bytesize % 4 != 1)
    String.new(Base64.decode(enc))
  rescue Base64::Error
    nil
  end

  # What a message asks for once the protocol version is settled. reply is
  # false for notifications and for answers of the client (we never send
  # requests).
  record Request, id : String?, method : String, params : Params, version : String, modern : Bool, reply : Bool

  def self.parse_request(body : String, headers : HTTP::Headers, info : RequestInfo) : Request
    raise RPCError.invalid_request("JSON-RPC batches are not supported.") if body.lstrip.starts_with?('[')
    message = parse_message(body)
    id, method = message.id, message.method
    info.method = method
    if method.empty?
      raise RPCError.invalid_request("Field method is missing.", id) unless message.answer?
      return Request.new(id, method, Params.new, "", false, false)
    end
    raise RPCError.invalid_request(%(jsonrpc must be "2.0".), id) unless message.jsonrpc == "2.0"
    params = message.params.try { |raw| parse_params(raw, id) } || Params.new
    reply = !id.nil?
    meta_version = params.meta.try(&.[META_PROTOCOL_VERSION]?).try do |value|
      value.as_s?.presence ||
        raise RPCError.invalid_params("_meta.#{META_PROTOCOL_VERSION} must be a non-empty string.", id)
    end
    modern = false
    if meta_version
      info.version = meta_version
      return Request.new(id, method, params, meta_version, false, false) unless reply
      check_headers(headers, method, params.name.to_s, meta_version, id)
      modern = MODERN_VERSIONS.includes?(meta_version)
      raise RPCError.unsupported(meta_version, id) unless modern || LEGACY_VERSIONS.includes?(meta_version)
    elsif method == "initialize"
      info.version = negotiate(params.protocol_version)
    else
      info.version = header(headers, "MCP-Protocol-Version").presence || LEGACY_DEFAULT
      if MODERN_VERSIONS.includes?(info.version)
        raise RPCError.header_mismatch(
          "Header MCP-Protocol-Version is #{info.version}, but params._meta[#{META_PROTOCOL_VERSION.inspect}] is missing.", id)
      end
      raise RPCError.unsupported(info.version, id) unless LEGACY_VERSIONS.includes?(info.version)
    end
    Request.new(id, method, params, info.version, modern, reply)
  end

  SERVER_INFO  = {name: "zipfelkasse", title: "Zipfelkasse – shared expenses", version: SERVER_VERSION}
  CAPABILITIES = {tools: {listChanged: false}}

  class Server
    def handle_post(ctx : HTTP::Server::Context, info : RequestInfo) : Nil
      http = ctx.request
      unless MCP.header(http.headers, "Content-Type").partition(';')[0].strip.downcase == "application/json"
        raise RPCError.new(415, CODE_INVALID_REQUEST, "Content-Type must be application/json.")
      end
      request = MCP.parse_request(read_body(http), http.headers, info)
      return accepted(ctx) unless request.reply
      result = dispatch(request, info)
      result = result.merge(resultType: "complete", _meta: {META_SERVER_INFO => SERVER_INFO}) if request.modern
      respond(ctx, 200, request.id) { |json| json.field("result", result) }
    rescue ex : RPCError
      write_error(ctx, ex.status, ex.id, ex)
    end

    private def read_body(req : HTTP::Request) : String
      io = req.body || return ""
      buffer = IO::Memory.new
      IO.copy(io, buffer, MAX_BODY + 1)
      raise RPCError.too_large if buffer.size > MAX_BODY
      buffer.to_s
    rescue IO::Error
      raise RPCError.too_large
    end

    private def accepted(ctx : HTTP::Server::Context) : Nil
      ctx.response.headers.delete("Content-Type")
      ctx.response.status_code = 202
    end

    private def respond(ctx : HTTP::Server::Context, status : Int32, id : String?, & : JSON::Builder ->) : Nil
      skip_unread(ctx)
      res = ctx.response
      res.status_code = status
      res.headers["Content-Type"] = "application/json"
      res.puts(JSON.build do |json|
        json.object do
          json.field "jsonrpc", "2.0"
          json.field("id") { json.raw(id) } if id
          yield json
        end
      end)
    end

    private def write_error(ctx : HTTP::Server::Context, status : Int32, id : String?, code : Int32, message : String,
                            data = nil) : Nil
      respond(ctx, status, id) do |json|
        json.field "error" do
          json.object do
            json.field "code", code
            json.field "message", message
            json.field "data", data if data
          end
        end
      end
    end

    private def write_error(ctx : HTTP::Server::Context, status : Int32, id : String?, ex : RPCError) : Nil
      write_error(ctx, status, id, ex.code, ex.message || "", ex.data)
    end

    private def dispatch(request : Request, info : RequestInfo)
      case request.method
      when "initialize"
        unless request.modern
          return {protocolVersion: request.version, capabilities: CAPABILITIES, serverInfo: SERVER_INFO,
                  instructions: instructions}
        end
      when "server/discover"
        return {supportedVersions: ALL_VERSIONS, capabilities: CAPABILITIES, instructions: instructions,
                _meta: {META_SERVER_INFO => SERVER_INFO}, ttlMs: discover_ttl.total_milliseconds.to_i64,
                cacheScope: "public"}
      when "ping" # removed in 2026-07-28, but harmless
        return NamedTuple.new
      when "tools/list"
        tools = {tools: @tools.values.map(&.definition)}
        return request.modern ? tools.merge(ttlMs: LIST_TTL.total_milliseconds.to_i64, cacheScope: "public") : tools
      when "tools/call"
        return call_tool(request.params, request.id, info)
      end
      raise RPCError.new(request.modern ? 404 : 200, CODE_METHOD_NOT_FOUND, "Unknown method: #{request.method}", request.id)
    end

    # Only the text, no structuredContent: a copy of the JSON in both would
    # double the size. Claude.ai/Desktop only pass content on to the model,
    # Claude Code and VS Code only structuredContent if it is there – and
    # content otherwise. Hence no outputSchema either (it requires
    # structuredContent).
    private def call_tool(params : Params, id : String?, info : RequestInfo)
      name = params.name.to_s
      tool = @tools[name]? || raise RPCError.new(200, CODE_INVALID_PARAMS, "Unknown tool: #{name}", id)
      info.tool = name
      error = false
      text = begin
        tool.run.call(params.arguments)
      rescue ex : Domain::ValidationError
        error = true
        ex.message || ""
      rescue ex
        Log.error(exception: ex, &.emit("mcp: tool failed", tool: name))
        error = true
        "Internal error while running the tool (details in the server log)."
      end
      info.tool_error = text if error
      {content: [{type: "text", text: text}], isError: error}
    end
  end
end
