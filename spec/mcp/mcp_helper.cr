require "../spec_helper"
require "file_utils"
require "../web/web_helper"

# No exchange rate for any currency.
class NoRates
  include Zipfelkasse::Web::FXRater

  def rate(currency : String, date : Time) : Zipfelkasse::Domain::FXRate
    raise "no rate"
  end
end

module MCPSpec
  SECRET    = "s3cr3t-0123456789abcdef"
  PATH      = "/mcp/#{SECRET}"
  ANTHROPIC = "160.79.104.10:40000" # in MCP_ALLOWED_CIDRS
  MODERN    = "2026-07-28"

  record Reply, status : Int32, headers : HTTP::Headers, body : String do
    def json : JSON::Any
      JSON.parse(body)
    end

    def result : JSON::Any
      json["result"]? || raise "no result (status #{status}): #{body}"
    end

    def error_code : Int64?
      json["error"]?.try(&.["code"].as_i64)
    end
  end

  # An MCP server on a store file (sql_query needs one) with Anna, Ben and
  # Cleo and the default categories.
  class Env
    getter store : Zipfelkasse::Store
    @server : Zipfelkasse::MCP::Server
    getter log_io = SPEC_LOG
    getter ids = {} of String => Int64
    getter cats = {} of String => Int64
    getter deps : Zipfelkasse::Web::Deps
    @dir : String

    def initialize(location = Time::Location::UTC)
      @dir = File.tempname("mcp-spec")
      Dir.mkdir_p(@dir)
      @store = Zipfelkasse::Store.open(File.join(@dir, "zipfelkasse.db"))
      config = Zipfelkasse::Config.from_env({"MCP_SECRET" => SECRET, "TRUSTED_PROXIES" => "10.0.0.1"})
      config.location = location
      @deps = Zipfelkasse::Web::Deps.new(config, @store)
      @deps.fx = NoRates.new
      @server = Zipfelkasse::MCP::Server.new(@deps)
      %w(Anna Ben Cleo).each { |n| @ids[n] = @store.create_participant(nil, n) }
      @store.list_categories(include_archived: true).each { |c| @cats[c.name] = c.id }
    end

    def close : Nil
      @store.close
      FileUtils.rm_rf(@dir)
    end

    def logs : String
      @log_io.to_s
    end

    # Stops the clock at noon of date (server time zone).
    def at(date : String) : Nil
      d = Zipfelkasse::Domain.parse_date(date)
      @deps.config.now = Time.local(d.year, d.month, d.day, 12, 0, 0, location: @deps.config.location)
    end

    def expense(title : String, cents : Int64, date : String, payer : String, category : String, *who : String) : Int64
      input = Zipfelkasse::Store::ExpenseInput.new(title: title, date: Zipfelkasse::Domain.parse_date(date), paid_by: @ids[payer],
        amount_cents: cents, category_id: @cats[category]?, parts: who.map { |w| Zipfelkasse::Domain::Part.new(@ids[w]) }.to_a)
      @store.create_expense(@ids[payer], input)
    end

    def reimbursement(cents : Int64, date : String, from : String, to : String) : Int64
      input = Zipfelkasse::Store::ExpenseInput.new(title: "Rückzahlung", date: Zipfelkasse::Domain.parse_date(date), paid_by: @ids[from],
        amount_cents: cents, reimbursement: true, parts: [Zipfelkasse::Domain::Part.new(@ids[to])])
      @store.create_expense(@ids[from], input)
    end

    # headers: an empty value removes the header; remote nil = no address.
    def send(method : String, path : String, body : String | IO = "", headers = {} of String => String,
             remote : String? = ANTHROPIC) : Reply
      h = HTTP::Headers{"Content-Type" => "application/json", "Accept" => "application/json, text/event-stream"}
      headers.each { |k, v| v.empty? ? h.delete(k) : (h[k] = v) }
      req = HTTP::Request.new(method, path, h, body)
      if remote
        host, _, port = remote.rpartition(':')
        req.remote_address = Socket::IPAddress.new(host.lchop('[').rchop(']'), port.to_i)
      end
      io = IO::Memory.new
      res = HTTP::Server::Response.new(io)
      @server.call(HTTP::Server::Context.new(req, res))
      res.close
      io.rewind
      r = HTTP::Client::Response.from_io(io)
      Reply.new(r.status_code, r.headers, r.body)
    end

    def post(body : String, headers = {} of String => String) : Reply
      send("POST", PATH, body, headers)
    end

    def self.body(method : String, params : String? = nil, id : String? = "1") : String
      parts = [%("jsonrpc":"2.0")]
      parts << %("id":#{id}) if id
      parts << %("method":#{method.to_json})
      parts << %("params":#{params}) if params
      "{#{parts.join(",")}}"
    end

    # A legacy request (header MCP-Protocol-Version 2025-06-18).
    def legacy(method : String, params : String? = nil) : Reply
      post(Env.body(method, params), {"MCP-Protocol-Version" => "2025-06-18"})
    end

    # A modern request with matching headers; headers override them.
    def modern(method : String, params = "{}", headers = {} of String => String) : Reply
      p = JSON.parse(params).as_h
      p["_meta"] ||= JSON.parse({"io.modelcontextprotocol/protocolVersion"    => MODERN,
                                 "io.modelcontextprotocol/clientInfo"         => {"name" => "test", "version" => "1"},
                                 "io.modelcontextprotocol/clientCapabilities" => {} of String => String}.to_json)
      h = {"MCP-Protocol-Version" => MODERN, "Mcp-Method" => method}
      p["name"]?.try(&.as_s?).try { |name| h["Mcp-Name"] = name }
      post(Env.body(method, p.to_json, %("a-1")), h.merge(headers))
    end

    # Calls a tool (legacy): the text parsed as JSON (nil if it is not
    # JSON), the text and isError.
    def call(name : String, args : String? = nil) : {JSON::Any?, String, Bool}
      params = %({"name":#{name.to_json}) + (args ? %(,"arguments":#{args}) : "") + "}"
      res = legacy("tools/call", params).result
      raise "#{name}: structuredContent duplicates the text" if res["structuredContent"]?
      text = res["content"][0]["text"].as_s
      data = begin
        JSON.parse(text)
      rescue JSON::ParseException
        nil
      end
      {data, text, res["isError"].as_bool}
    end

    # The data of a successful tool call.
    def ok(name : String, args : String? = nil) : JSON::Any
      data, text, error = call(name, args)
      raise "#{name} #{args}: #{text}" if error || data.nil?
      data
    end

    # The message of a failed tool call.
    def fail(name : String, args : String? = nil) : String
      _, text, error = call(name, args)
      raise "#{name} #{args}: expected an error, got #{text}" unless error
      text
    end
  end

  def self.with_env(location = Time::Location::UTC, &)
    e = Env.new(location)
    begin
      yield e
    ensure
      e.close
    end
  end
end
