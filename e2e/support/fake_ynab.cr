require "http/server"
require "json"

module E2E
  # In-memory fake of the YNAB API, reachable at base_url (".../v1").
  class FakeYNAB
    TOKEN       = "geheimer-token-123"
    OTHER_TOKEN = "token-anderer-nutzer"
    PLAN        = "plan-1"
    ACCOUNT     = "acc-geteilt"

    ACCOUNTS = [
      {"id" => ACCOUNT, "name" => "Geteilt", "type" => "cash", "on_budget" => true, "closed" => false, "deleted" => false},
      {"id" => "acc-giro", "name" => "Girokonto", "type" => "checking", "on_budget" => true, "closed" => false, "deleted" => false},
      {"id" => "acc-depot", "name" => "Depot", "type" => "otherAsset", "on_budget" => false, "closed" => false, "deleted" => false},
      {"id" => "acc-alt", "name" => "Altes Konto", "type" => "checking", "on_budget" => true, "closed" => true, "deleted" => false},
    ]

    class Txn
      include JSON::Serializable
      property id : String
      property account_id : String = ""
      property date : String = ""
      property amount : Int64 = 0
      property memo : String? = nil
      property payee_name : String? = nil
      property category_id : String? = nil
      property cleared : String = ""
      property approved : Bool = false
      property deleted : Bool = false

      def initialize(@id)
      end
    end

    getter port : Int32
    getter requests = [] of String
    @txns = {} of String => Txn
    @next_id = 0
    @fail_next = [] of Int32
    @last_request = Time.instant
    @mutex = Mutex.new
    @server : HTTP::Server

    def initialize
      @server = HTTP::Server.new { |ctx| handle(ctx) }
      @port = @server.bind_tcp("127.0.0.1", 0).port
      spawn { @server.listen }
    end

    def base_url : String
      "http://127.0.0.1:#{@port}/v1"
    end

    def close : Nil
      @server.close
    end

    # Non-deleted transactions sorted by ID number.
    def live : Array(Txn)
      @mutex.synchronize { @txns.values.reject(&.deleted).sort_by { |t| t.id[1..].to_i } }
    end

    def all : Array(Txn)
      @mutex.synchronize { @txns.values.sort_by { |t| t.id[1..].to_i } }
    end

    def fail(*statuses : Int32) : Nil
      @mutex.synchronize { @fail_next.concat(statuses.to_a) }
    end

    def request_count : Int32
      @mutex.synchronize { @requests.size }
    end

    # Waits until the app has not talked to the fake for `quiet`.
    def wait_idle(quiet = 1.5.seconds, timeout = 30.seconds) : Nil
      E2E.wait_until("YNAB fake idle", timeout) do
        @mutex.synchronize { Time.instant - @last_request > quiet }
      end
    end

    private def handle(ctx)
      req = ctx.request
      fail = 0
      @mutex.synchronize do
        @requests << "#{req.method} #{req.path}"
        @last_request = Time.instant
        fail = @fail_next.shift? || 0
      end
      auth = req.headers["Authorization"]?
      res = ctx.response
      res.content_type = "application/json"
      if auth != "Bearer #{TOKEN}" && auth != "Bearer #{OTHER_TOKEN}"
        error(res, 401, "401", "unauthorized", "Unauthorized")
      elsif fail == 429
        res.headers["Retry-After"] = "60"
        error(res, 429, "429", "too_many_requests", "Too many requests")
      elsif fail != 0
        error(res, fail, fail.to_s, "error", "Fehler #{fail} mit #{TOKEN}")
      elsif auth == "Bearer #{OTHER_TOKEN}"
        other_user(req, res)
      else
        route(req, res)
      end
    ensure
      @mutex.synchronize { @last_request = Time.instant }
    end

    private def route(req, res)
      parts = req.path.split('/', remove_empty: true)
      return error(res, 404, "404", "not_found", "path") unless parts[0]? == "v1" && parts[1]? == "plans"
      case {req.method, parts.size}
      when {"GET", 2}
        plans(req, res)
      when {"GET", 4}
        parts[3] == "categories" ? categories(parts[2], res) : not_found(res)
      when {"POST", 4}, {"PATCH", 4}
        return not_found(res) unless parts[3] == "transactions"
        req.method == "POST" ? create(req, res) : update(req, res)
      when {"DELETE", 5}
        parts[3] == "transactions" ? delete(parts[4], res) : not_found(res)
      when {"GET", 5}
        parts[3] == "accounts" ? account(parts[2], parts[4], res) : not_found(res)
      when {"GET", 6}
        parts[3] == "accounts" && parts[5] == "transactions" ? list(parts[4], req, res) : not_found(res)
      else
        not_found(res)
      end
    end

    private def not_found(res)
      error(res, 404, "404.2", "resource_not_found", "Resource not found")
    end

    private def error(res, status, id, name, detail)
      res.status_code = status
      {error: {id: id, name: name, detail: detail}}.to_json(res)
    end

    private def data(res, status, payload)
      res.status_code = status
      {data: payload}.to_json(res)
    end

    private def plans(req, res)
      unless req.query_params["include_accounts"]? == "true"
        return error(res, 400, "400", "bad_request", "include_accounts missing")
      end
      data(res, 200, {plans: [{
        id: PLAN, name: "Haushalt", currency_format: {iso_code: "EUR"}, accounts: ACCOUNTS,
      }]})
    end

    private def other_user(req, res)
      if req.method == "GET" && req.path == "/v1/plans"
        data(res, 200, {plans: [{
          id: "plan-2", name: "Anderer Haushalt",
          accounts: [{"id" => "acc-2", "name" => "Geteilt", "type" => "cash", "on_budget" => true, "closed" => false, "deleted" => false}],
        }]})
      else
        not_found(res)
      end
    end

    private def account(plan, acc, res)
      if plan == PLAN && (a = ACCOUNTS.find { |x| x["id"] == acc })
        data(res, 200, {account: a})
      else
        not_found(res)
      end
    end

    private def categories(plan, res)
      return error(res, 404, "404", "not_found", "plan") unless plan == PLAN
      cat = ->(id : String, name : String, hidden : Bool) { {id: id, name: name, hidden: hidden, deleted: false} }
      data(res, 200, {server_knowledge: 1, category_groups: [
        {id: "g-int", name: "Internal Master Category", hidden: false, internal: true, deleted: false,
         categories: [cat.call("c-rta", "Inflow: Ready to Assign", false)]},
        {id: "g-cc", name: "Credit Card Payments", hidden: false, internal: false, deleted: false,
         categories: [cat.call("c-visa", "Visa", false)]},
        {id: "g-1", name: "Alltag", hidden: false, internal: false, deleted: false,
         categories: [
           cat.call("c-food", "Lebensmittel & Drogerie", false),
           cat.call("c-out", "Essen gehen", false),
           cat.call("c-old", "Versteckt", true),
         ]},
        {id: "g-2", name: "Wohnen & <Freizeit>", hidden: false, internal: false, deleted: false,
         categories: [
           cat.call("c-rent", "Miete", false),
           cat.call("c-fun", "Kino & \"Konzerte\"", false),
         ]},
      ]})
    end

    private def body_txns(req) : Array(JSON::Any)?
      JSON.parse(req.body.try(&.gets_to_end) || "")["transactions"]?.try(&.as_a?)
    rescue JSON::ParseException
      nil
    end

    private def create(req, res)
      txns = body_txns(req)
      return error(res, 400, "400", "bad_request", "kaputt") if txns.nil? || txns.empty?
      @mutex.synchronize do
        txns.each do |t|
          return error(res, 400, "400", "bad_request", "import_id not expected") if t.as_h.has_key?("import_id")
          if t["payee_name"]?.try(&.as_s?).try(&.includes?("ABLEHNEN"))
            return error(res, 400, "400", "bad_request", "payee rejected")
          end
        end
        out = txns.map do |t|
          @next_id += 1
          txn = Txn.new("t#{@next_id}")
          apply(txn, t)
          @txns[txn.id] = txn
        end
        data(res, 201, {transaction_ids: out.map(&.id), transactions: out, server_knowledge: 2})
      end
    end

    private def update(req, res)
      txns = body_txns(req)
      return error(res, 400, "400", "bad_request", "kaputt") if txns.nil?
      @mutex.synchronize do
        txns.each do |t|
          return error(res, 404, "404", "not_found", "transaction not found") unless @txns.has_key?(t["id"]?.try(&.as_s?) || "")
        end
        out = txns.map do |t|
          txn = @txns[t["id"].as_s]
          apply(txn, t) unless txn.deleted
          txn
        end
        data(res, 200, {transaction_ids: [] of String, transactions: out, server_knowledge: 3})
      end
    end

    private def delete(id, res)
      @mutex.synchronize do
        txn = @txns[id]?
        return error(res, 404, "404", "not_found", "transaction not found") if txn.nil? || txn.deleted
        txn.deleted = true
        data(res, 200, {transaction: txn, server_knowledge: 4})
      end
    end

    private def list(acc, req, res)
      since = req.query_params["since_date"]? || ""
      @mutex.synchronize do
        out = @txns.values.select { |t| !t.deleted && t.account_id == acc && t.date >= since }
        data(res, 200, {transactions: out, server_knowledge: 5})
      end
    end

    private def apply(txn : Txn, t : JSON::Any)
      h = t.as_h
      h["account_id"]?.try(&.as_s?).try { |v| txn.account_id = v }
      h["date"]?.try(&.as_s?).try { |v| txn.date = v }
      h["amount"]?.try { |v| txn.amount = v.as_i64? || v.as_f.to_i64 }
      h["memo"]?.try(&.as_s?).try { |v| txn.memo = v }
      h["payee_name"]?.try(&.as_s?).try { |v| txn.payee_name = v }
      if h.has_key?("category_id")
        txn.category_id = h["category_id"].as_s?
      end
      h["cleared"]?.try(&.as_s?).try { |v| txn.cleared = v }
      h["approved"]?.try(&.as_bool?).try { |v| txn.approved = v }
    end
  end
end
