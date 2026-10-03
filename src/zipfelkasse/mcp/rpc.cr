require "base64"
require "json"

module Zipfelkasse::MCP
  # Modern = stateless with _meta per request, legacy = initialize handshake.
  # The first version of each list is the preferred one.
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

  # Cache hint (ttlMs) for tools/list and server/discover.
  LIST_TTL = 1.hour

  class RPCError < Exception
    getter code : Int32
    getter data : JSON::Any?

    def initialize(@code, message : String, @data = nil)
      super(message)
    end
  end

  # A JSON object decoded with JSON::Serializable; decode_error names the
  # field of a wrongly typed value and the expected type.
  module Decodable
    macro included
      include JSON::Serializable

      def self.expected(field : String) : String
        \{% begin %}
          case field
          \{% for ivar in @type.instance_vars %}
            \{% ann = ivar.annotation(::JSON::Field) %}
            \{% t = ivar.type.union_types.reject(&.nilable?).first %}
            when \{{(ann && ann[:key]) || ivar.name.stringify}}
              \{{t == String ? "a string" : t <= Int ? "an integer" : t <= Float ? "a number" : t == Bool ? "true or false" : t <= Array ? "a list of strings" : "an object"}}
          \{% end %}
          else "something else"
          end
        \{% end %}
      end
    end
  end

  # whole names the object itself.
  def self.decode_error(type : T.class, ex : JSON::SerializableError, whole : String) : String forall T
    field = ex.attribute || return "#{whole} must be an object."
    "#{field} must be #{T.expected(field)}."
  end

  # Raw JSON, for values that are passed on or echoed unchanged.
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

    # A response from the client.
    def answer? : Bool
      @result_present || @error_present
    end
  end

  struct Params
    include Decodable

    @[JSON::Field(key: "_meta")]
    getter meta : Hash(String, JSON::Any)? = nil
    getter name = ""
    @[JSON::Field(converter: Zipfelkasse::MCP::RawJSON)]
    getter arguments : String? = nil
    @[JSON::Field(key: "protocolVersion")]
    getter protocol_version = ""

    def initialize
    end
  end

  # Raises an RPCError (parse error) for invalid JSON and wrongly typed
  # fields.
  def self.parse_message(body : String) : Message
    pull = JSON::PullParser.new(body)
    m = pull.kind.null? ? (pull.read_null; Message.new) : Message.new(pull)
    raise JSON::ParseException.new("Unexpected data after the message", *pull.location) unless pull.kind.eof?
    m
  rescue ex : JSON::SerializableError
    message = begin
      JSON.parse(body) # a syntax error inside a field is not a wrong type
      decode_error(Message, ex, "the message")
    rescue syntax : JSON::ParseException
      syntax.message
    end
    raise RPCError.new(CODE_PARSE_ERROR, "Invalid JSON: #{message}")
  rescue ex : JSON::ParseException
    raise RPCError.new(CODE_PARSE_ERROR, "Invalid JSON: #{ex.message}")
  end

  def self.parse_params(raw : String) : Params
    Params.from_json(raw)
  rescue ex : JSON::SerializableError
    raise RPCError.new(CODE_INVALID_PARAMS, "Invalid params: #{decode_error(Params, ex, "params")}")
  end

  # Picks the legacy version for initialize: the requested one if supported,
  # otherwise the newest.
  def self.negotiate(requested : String) : String
    LEGACY_VERSIONS.includes?(requested) ? requested : LEGACY_VERSIONS.first
  end

  def self.unsupported(version : String) : RPCError
    RPCError.new(CODE_UNSUPPORTED_VERSION, "Unsupported protocol version.",
      JSON::Any.new({"supported" => JSON::Any.new(ALL_VERSIONS.map { |v| JSON::Any.new(v) }), "requested" => JSON::Any.new(version)}))
  end

  # The first value of a header, without the whitespace around it.
  def self.header(headers : HTTP::Headers, name : String) : String
    headers.get?(name).try(&.first?).try(&.strip) || ""
  end

  # The mandatory headers of modern requests against the body; the error
  # message, or nil when they match.
  def self.check_headers(req : HTTP::Request, method : String, name : String, version : String) : String?
    h = header(req.headers, "MCP-Protocol-Version")
    return "Header mismatch: header MCP-Protocol-Version is missing." if h.empty?
    return "Header mismatch: MCP-Protocol-Version #{h.inspect} does not match _meta #{version.inspect}." if h != version
    h = header(req.headers, "Mcp-Method")
    return "Header mismatch: header Mcp-Method is missing." if h.empty?
    return "Header mismatch: Mcp-Method #{h.inspect} does not match method #{method.inspect}." if h != method
    return unless method == "tools/call"
    h = header(req.headers, "Mcp-Name")
    return "Header mismatch: header Mcp-Name is missing." if h.empty?
    v = decode_header_value(h) || return "Header mismatch: Mcp-Name is not valid Base64."
    "Header mismatch: Mcp-Name #{v.inspect} does not match params.name #{name.inspect}." if v != name
  end

  # Decodes the Base64 form =?base64?…?=; other values are returned as they
  # are, nil means broken Base64.
  def self.decode_header_value(v : String) : String?
    prefix, suffix = "=?base64?", "?="
    return v unless v.starts_with?(prefix) && v.ends_with?(suffix) && v.bytesize >= prefix.bytesize + suffix.bytesize
    enc = v.byte_slice(prefix.bytesize, v.bytesize - prefix.bytesize - suffix.bytesize)
    return unless enc.matches?(/\A[A-Za-z0-9+\/]*={0,2}\z/) && (enc.ends_with?('=') ? enc.bytesize % 4 == 0 : enc.bytesize % 4 != 1)
    String.new(Base64.decode(enc))
  rescue Base64::Error
    nil
  end

  # Objects with sorted keys, so that the output is stable.
  def self.write_any(j : JSON::Builder, v : JSON::Any) : Nil
    case raw = v.raw
    when Hash  then j.object { raw.keys.sort!.each { |k| j.field(k) { write_any(j, raw[k]) } } }
    when Array then j.array { raw.each { |x| write_any(j, x) } }
    else            v.to_json(j)
    end
  end

  class Server
    # Answers exactly one JSON-RPC message.
    def handle_post(ctx : HTTP::Server::Context, info : RequestInfo) : Nil
      req = ctx.request
      unless MCP.header(req.headers, "Content-Type").partition(';')[0].strip.downcase == "application/json"
        return write_error(ctx, 415, nil, CODE_INVALID_REQUEST, "Content-Type must be application/json.")
      end
      unless body = read_body(req)
        return write_error(ctx, 413, nil, CODE_INVALID_REQUEST, "Message too large or incomplete.")
      end
      if body.lstrip.starts_with?('[')
        return write_error(ctx, 400, nil, CODE_INVALID_REQUEST, "JSON-RPC batches are not supported.")
      end
      m = begin
        MCP.parse_message(body)
      rescue ex : RPCError
        return write_error(ctx, 400, nil, ex.code, ex.message || "")
      end
      info.method = m.method
      if m.method.empty?
        return accepted(ctx) if m.answer? # we never send requests
        return write_error(ctx, 400, m.id, CODE_INVALID_REQUEST, "Field method is missing.")
      end
      return write_error(ctx, 400, m.id, CODE_INVALID_REQUEST, %(jsonrpc must be "2.0".)) unless m.jsonrpc == "2.0"
      p = Params.new
      if raw = m.params
        begin
          p = MCP.parse_params(raw)
        rescue ex : RPCError
          return write_error(ctx, 400, m.id, ex.code, ex.message || "")
        end
      end
      meta_version = ""
      if v = p.meta.try(&.[META_PROTOCOL_VERSION]?)
        meta_version = v.as_s? || ""
        if meta_version.empty?
          return write_error(ctx, 400, m.id, CODE_INVALID_PARAMS, "_meta.#{META_PROTOCOL_VERSION} must be a non-empty string.")
        end
      end
      notification = m.id.nil?

      modern = false
      if !meta_version.empty?
        # Modern request: the version is in the body, headers must match it.
        info.version = meta_version
        return accepted(ctx) if notification
        if msg = MCP.check_headers(req, m.method, p.name, meta_version)
          return write_error(ctx, 400, m.id, CODE_HEADER_MISMATCH, msg)
        end
        if MODERN_VERSIONS.includes?(meta_version)
          modern = true
        elsif !LEGACY_VERSIONS.includes?(meta_version) # an older version with _meta is answered like legacy
          return write_error(ctx, 400, m.id, MCP.unsupported(meta_version))
        end
      elsif m.method == "initialize"
        info.version = MCP.negotiate(p.protocol_version)
      else
        v = MCP.header(req.headers, "MCP-Protocol-Version").presence || LEGACY_DEFAULT
        info.version = v
        if MODERN_VERSIONS.includes?(v)
          return write_error(ctx, 400, m.id, CODE_HEADER_MISMATCH,
            "Header MCP-Protocol-Version is #{v}, but params._meta[#{META_PROTOCOL_VERSION.inspect}] is missing.")
        end
        return write_error(ctx, 400, m.id, MCP.unsupported(v)) unless LEGACY_VERSIONS.includes?(v)
      end
      return accepted(ctx) if notification

      result = begin
        dispatch(modern, m.method, p, info)
      rescue ex : RPCError
        # Required by spec 2026-07-28.
        status = modern && ex.code == CODE_METHOD_NOT_FOUND ? 404 : 200
        return write_error(ctx, status, m.id, ex)
      end
      if modern
        result["resultType"] = JSON::Any.new("complete")
        meta = result["_meta"]?.try(&.as_h?) || {} of String => JSON::Any
        meta[META_SERVER_INFO] = MCP.server_info
        result["_meta"] = JSON::Any.new(meta)
      end
      respond(ctx, 200, m.id) { |j| j.field("result") { MCP.write_any(j, JSON::Any.new(result)) } }
    end

    private def read_body(req : HTTP::Request) : String?
      io = req.body || return ""
      buf = IO::Memory.new
      IO.copy(io, buf, MAX_BODY + 1)
      buf.size > MAX_BODY ? nil : buf.to_s
    rescue IO::Error
      nil
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
      json = JSON.build do |j|
        j.object do
          j.field "jsonrpc", "2.0"
          j.field("id") { j.raw(id) } if id
          yield j
        end
      end
      res.print json, '\n'
    end

    private def write_error(ctx : HTTP::Server::Context, status : Int32, id : String?, code : Int32, message : String,
                            data : JSON::Any? = nil) : Nil
      respond(ctx, status, id) do |j|
        j.field "error" do
          j.object do
            j.field "code", code
            j.field "message", message
            j.field("data") { MCP.write_any(j, data) } if data
          end
        end
      end
    end

    private def write_error(ctx : HTTP::Server::Context, status : Int32, id : String?, ex : RPCError) : Nil
      write_error(ctx, status, id, ex.code, ex.message || "", ex.data)
    end

    # Results are hashes so that handle_post can add the modern fields.
    private def dispatch(modern : Bool, method : String, p : Params, info : RequestInfo) : Hash(String, JSON::Any)
      case method
      when "initialize"
        unless modern
          return {
            "protocolVersion" => JSON::Any.new(info.version),
            "capabilities"    => MCP.capabilities,
            "serverInfo"      => MCP.server_info,
            "instructions"    => JSON::Any.new(instructions),
          }
        end
      when "server/discover"
        return {
          "supportedVersions" => JSON::Any.new(ALL_VERSIONS.map { |v| JSON::Any.new(v) }),
          "capabilities"      => MCP.capabilities,
          "instructions"      => JSON::Any.new(instructions),
          "_meta"             => JSON::Any.new({META_SERVER_INFO => MCP.server_info}),
          "ttlMs"             => JSON::Any.new(discover_ttl.total_milliseconds.to_i64),
          "cacheScope"        => JSON::Any.new("public"),
        }
      when "ping" # removed in 2026-07-28, but harmless
        return {} of String => JSON::Any
      when "tools/list"
        res = {"tools" => JSON::Any.new(@order.map { |name| @tools[name].definition })}
        if modern
          res["ttlMs"] = JSON::Any.new(LIST_TTL.total_milliseconds.to_i64)
          res["cacheScope"] = JSON::Any.new("public")
        end
        return res
      when "tools/call"
        return call_tool(p, info)
      end
      raise RPCError.new(CODE_METHOD_NOT_FOUND, "Unknown method: #{method}")
    end

    # Only the text, no structuredContent: a copy of the JSON in both would
    # double the size. Claude.ai/Desktop only pass content on to the model,
    # Claude Code and VS Code only structuredContent if it is there – and
    # content otherwise. Hence no outputSchema either (it requires
    # structuredContent).
    private def call_tool(p : Params, info : RequestInfo) : Hash(String, JSON::Any)
      tool = @tools[p.name]? || raise RPCError.new(CODE_INVALID_PARAMS, "Unknown tool: #{p.name}")
      info.tool = p.name
      error = false
      text = begin
        tool.run.call(p.arguments)
      rescue ex : Domain::ValidationError
        error = true
        ex.message || ""
      rescue ex
        @log.error("mcp: tool failed", tool: p.name, err: ex)
        error = true
        "Internal error while running the tool (details in the server log)."
      end
      info.tool_error = text if error
      content = {"type" => JSON::Any.new("text"), "text" => JSON::Any.new(text)}
      {"content" => JSON::Any.new([JSON::Any.new(content)]), "isError" => JSON::Any.new(error)}
    end
  end
end
