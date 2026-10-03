require "json"
require "base64"

module E2E
  # Helpers for the MCP scenarios (e2e/mcp_spec.cr): raw JSON-RPC requests,
  # the modern protocol's headers and the unpacking of tool results.
  module MCPKit
    PATH   = "/mcp/#{MCP_SECRET}"
    MODERN = "2026-07-28"
    LEGACY = ["2025-11-25", "2025-06-18", "2025-03-26"]
    ALL    = [MODERN] + LEGACY

    # The instructions without the date line and the data overview.
    INSTRUCTIONS = <<-TEXT
      Zipfelkasse manages the shared expenses of a single group (like Splitwise/Spliit). All tools are read-only except create_expense and create_reimbursement, which add entries (nothing can be changed or deleted via MCP).
      Amounts are in euros. Every amount in a result appears twice: as text with a dot as decimal separator and no thousands separator ("1234.56") and as an integer in cents (field ending in _cents).
      Balance: positive = is owed money by the others, negative = owes money.
      Reimbursements are settlement payments between two people, not expenses; they count for balances, not for expense statistics.
      Dates use the format YYYY-MM-DD. Refer to people and categories by name (case-insensitive). Names, titles, categories and notes are stored as entered (often in German).
      How to proceed: balances and settlement → balances; their development over time → balance_history. Finding individual expenses → search_expenses. Totals by category, merchant, period or person, also compared with the previous year → statistics. Who changed what when → activity.
      Anything else → read schema first, then sql_query (SQLite, SELECT only).
      Entering an expense → create_expense; a settlement payment between two people → create_reimbursement. Confirm unclear details with the user first and report what was created.
      TEXT

    SECURITY_HEADERS = {
      "X-Content-Type-Options"  => "nosniff",
      "Referrer-Policy"         => "same-origin",
      "X-Frame-Options"         => "DENY",
      "Content-Security-Policy" => "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'",
    }

    def self.today_line(date : String, weekday : String) : String
      %(Today is #{date} (#{weekday}), server time zone Europe/Berlin. Resolve relative periods such as "last month" from this date.)
    end

    # Headers of an MCP request without identity cookie.
    def self.headers(extra = {} of String => String) : HTTP::Headers
      h = HTTP::Headers{"Cookie" => ""}
      extra.each { |k, v| h.add(k, v) }
      h
    end

    # POSTs a raw body to the MCP endpoint.
    def self.post(user : User, body : String, extra = {} of String => String,
                  content_type = "application/json", path = PATH) : Response
      user.run { |b| b.post_raw(path, body, content_type, headers(extra)) }
    end

    # Any request to the MCP endpoint.
    def self.request(user : User, method : String, extra = {} of String => String, body : String? = nil, path = PATH) : Response
      user.run { |b| b.request(method, path, headers(extra), body) }
    end

    # JSON-RPC request body.
    def self.body(method : String, params : String? = nil, id : String? = "1") : String
      parts = [%("jsonrpc":"2.0")]
      parts << %("id":#{id}) if id
      parts << %("method":#{method.to_json})
      parts << %("params":#{params}) if params
      "{#{parts.join(",")}}"
    end

    # A legacy request (no protocol headers).
    def self.rpc(user : User, method : String, params : String? = nil, id : String? = "1", extra = {} of String => String) : Response
      post(user, body(method, params, id), extra)
    end

    # A modern (2026-07-28) request: version in params._meta and the
    # mandatory headers. *headers* replaces the computed ones.
    def self.modern(user : User, method : String, params = "{}", id : String? = %("a-1"),
                    version = MODERN, headers : Hash(String, String)? = nil) : Response
      p = JSON.parse(params).as_h
      p["_meta"] = JSON.parse({"io.modelcontextprotocol/protocolVersion" => version}.to_json)
      h = headers || modern_headers(method, p["name"]?.try(&.as_s?), version)
      post(user, body(method, p.to_json, id), h)
    end

    def self.modern_headers(method : String, name : String? = nil, version = MODERN) : Hash(String, String)
      h = {"MCP-Protocol-Version" => version, "Mcp-Method" => method}
      h["Mcp-Name"] = name if name
      h
    end

    # tools/call with arguments given as JSON text (sent as they are).
    def self.call(user : User, name : String, arguments : String? = "{}") : Response
      params = %({"name":#{name.to_json}) + (arguments ? %(,"arguments":#{arguments}) : "") + "}"
      rpc(user, "tools/call", params)
    end

    # The JSON-RPC result of a successful answer.
    def self.result(r : Response) : JSON::Any
      raise "expected 200, got #{r.status}: #{r.body}" unless r.status == 200
      j = r.json
      raise "expected a result: #{r.body}" unless j["result"]?
      j["result"]
    end

    # {code, message} of a JSON-RPC error answer.
    def self.error(r : Response) : {Int64, String}
      e = r.json["error"]? || raise "expected an error: #{r.body}"
      {e["code"].as_i64, e["message"].as_s}
    end

    # The text of a tool result; *error* says whether isError is expected.
    def self.text(r : Response, error = false) : String
      res = result(r)
      unless res["isError"].as_bool == error
        raise "expected isError=#{error}: #{res["content"][0]["text"]}"
      end
      content = res["content"].as_a
      raise "expected one content item: #{r.body}" unless content.size == 1 && content[0]["type"] == "text"
      content[0]["text"].as_s
    end

    # The parsed JSON of a successful tool result.
    def self.data(r : Response) : JSON::Any
      JSON.parse(text(r))
    end

    def self.ok(user : User, name : String, arguments = "{}") : JSON::Any
      data(call(user, name, arguments))
    end

    # The message of a failed tool call (isError).
    def self.fail(user : User, name : String, arguments : String) : String
      text(call(user, name, arguments), error: true)
    end

    # A tool call refused by argument decoding: the message must name the
    # offending field.
    def self.decode_fail(user : User, name : String, arguments : String, field : String) : Nil
      msg = text(post(user, body("tools/call", %({"name":#{name.to_json},"arguments":#{arguments}}))), error: true)
      raise "#{name} #{arguments}: #{msg.inspect} does not mention #{field}" unless msg.includes?(field)
      raise "#{name} #{arguments}: internal error #{msg.inspect}" if msg.includes?("Internal error")
    end

    def self.json(text : String) : JSON::Any
      JSON.parse(text)
    end

    def self.b64(s : String) : String
      "=?base64?#{Base64.strict_encode(s)}?="
    end
  end
end
