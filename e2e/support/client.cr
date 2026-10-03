require "http/client"
require "uri"
require "json"
require "xml"
require "base64"

module E2E
  # One HTTP response, with helpers for the assertions of the suite.
  class Response
    getter method : String
    getter path : String
    getter status : Int32
    getter headers : HTTP::Headers
    getter body : String
    getter cookies : HTTP::Cookies

    def initialize(@method, @path, @status, @headers, @body, @cookies)
    end

    def location : String?
      @headers["Location"]?
    end

    def content_type : String
      @headers["Content-Type"]? || ""
    end

    def html? : Bool
      content_type.starts_with?("text/html")
    end

    def json : JSON::Any
      JSON.parse(@body)
    end

    def doc : XML::Node
      @doc ||= XML.parse_html(@body)
    end

    # The decoded flash message set by this response, if any.
    def flash : String?
      c = @cookies["flash"]?
      return nil if c.nil? || c.value.empty?
      URI.decode_www_form(c.value)
    end

    # The text of the error alert (`role="alert"`), if any.
    def error_message : String?
      doc.xpath_node(%(//*[@role="alert"])).try(&.content.strip)
    end

    # Visible text of the page with whitespace collapsed.
    def text : String
      doc.xpath_node("//body").try(&.content.gsub(/\s+/, " ").strip) || ""
    end

    # `<script>` elements without src and on* attributes: what an escaping
    # bug would produce. The app's CSP forbids both anyway.
    def injected_scripts : Array(String)
      found = [] of String
      doc.xpath_nodes("//script[not(@src)]").each { |n| found << n.to_s }
      doc.xpath_nodes("//*[@*[starts-with(name(), 'on')]]").each { |n| found << n.to_s[0, 200] }
      found
    end

    def to_s(io : IO) : Nil
      io << @method << " " << @path << " → " << @status
    end
  end

  # A browser for one app: keeps cookies, sends forms like a browser does,
  # never follows redirects.
  class Browser
    getter app : App
    getter jar = HTTP::Cookies.new

    def initialize(@app)
    end

    def get(path : String, headers = HTTP::Headers.new) : Response
      request("GET", path, headers)
    end

    def head(path : String) : Response
      request("HEAD", path, HTTP::Headers.new)
    end

    # POSTs a form; values can repeat (e.g. several "teil").
    def post(path : String, form : Enumerable({String, String}) = [] of {String, String}, headers = HTTP::Headers.new) : Response
      body = URI::Params.build do |p|
        form.each { |k, v| p.add(k, v) }
      end
      headers = headers.dup
      headers["Content-Type"] = "application/x-www-form-urlencoded"
      headers["Origin"] ||= @app.base_url
      headers["Sec-Fetch-Site"] ||= "same-origin"
      request("POST", path, headers, body)
    end

    def post_raw(path : String, body : String, content_type : String, headers = HTTP::Headers.new) : Response
      headers = headers.dup
      headers["Content-Type"] = content_type
      request("POST", path, headers, body)
    end

    def request(method : String, path : String, headers : HTTP::Headers, body : String? = nil, chunked = false) : Response
      headers = headers.dup
      @jar.add_request_headers(headers) unless headers.has_key?("Cookie")
      res = if body && (chunked || body.bytesize > LARGE_BODY)
              exec_raw(method, path, headers, body, chunked)
            else
              HTTP::Client.new(URI.parse(@app.base_url)) do |client|
                client.read_timeout = 30.seconds
                client.exec(method, path, headers, body)
              end
            end
      res.cookies.each do |c|
        if c.max_age == Time::Span.zero || c.value.empty?
          @jar.delete(c.name)
        else
          @jar << c
        end
      end
      Response.new(method, path, res.status_code, res.headers, res.body? || "", res.cookies)
    end

    LARGE_BODY = 64 << 10
    CHUNK_SIZE = 64 << 10

    # A server may answer a large body before reading it and then close the
    # connection; HTTP::Client would fail writing and never see the answer.
    # The body is written in a fiber while the answer is read.
    private def exec_raw(method : String, path : String, headers : HTTP::Headers, body : String, chunked : Bool) : HTTP::Client::Response
      socket = TCPSocket.new("127.0.0.1", @app.port)
      socket.read_timeout = 30.seconds
      socket << method << ' ' << path << " HTTP/1.1\r\nHost: " << @app.host << "\r\n"
      socket << (chunked ? "Transfer-Encoding: chunked" : "Content-Length: #{body.bytesize}") << "\r\n"
      headers.each { |name, values| values.each { |v| socket << name << ": " << v << "\r\n" } }
      socket << "\r\n"
      socket.flush
      spawn do
        if chunked
          bytes = body.to_slice
          (0...bytes.size).step(CHUNK_SIZE) do |pos|
            part = bytes[pos, Math.min(CHUNK_SIZE, bytes.size - pos)]
            socket << part.size.to_s(16) << "\r\n"
            socket.write(part)
            socket << "\r\n"
          end
          socket << "0\r\n\r\n"
        else
          socket << body
        end
        socket.flush
      rescue IO::Error
      end
      HTTP::Client::Response.from_io(socket)
    ensure
      socket.try &.close
    end

    # The participant ID this browser is logged in as (cookie `wer`).
    def me : Int64?
      @jar["wer"]?.try(&.value.to_i64?)
    end

    # An MCP request of protocol 2026-07-28 with the headers that match it.
    def mcp(method : String, params = {} of String => JSON::Any, id = 1) : Response
      version = "2026-07-28"
      params = params.merge({"_meta" => JSON.parse({"io.modelcontextprotocol/protocolVersion" => version}.to_json)})
      headers = HTTP::Headers{"Cookie" => "", "MCP-Protocol-Version" => version, "Mcp-Method" => method}
      params["name"]?.try { |name| headers["Mcp-Name"] = name.as_s }
      body = {jsonrpc: "2.0", id: id, method: method, params: params}.to_json
      post_raw("/mcp/#{MCP_SECRET}", body, "application/json", headers)
    end

    def tool(name : String, arguments = {} of String => JSON::Any) : Response
      mcp("tools/call", {"name" => JSON::Any.new(name), "arguments" => JSON.parse(arguments.to_json)})
    end
  end
end
