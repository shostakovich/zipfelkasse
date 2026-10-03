require "json"

module Zipfelkasse::YNAB
  # Budgets are called "plans" since API v1.79.
  DEFAULT_BASE_URL = "https://api.ynab.com/v1"

  MAX_PAYEE_LEN = 200
  MAX_MEMO_LEN  = 500
  HTTP_TIMEOUT  = 30.seconds
  MAX_BODY      = 64 << 20

  class APIError < Exception
    getter status : Int32
    getter retry_after : Time::Span

    def initialize(@status, detail : String? = nil, @retry_after = Time::Span.zero)
      super(case status
      when 401 then "YNAB: Token ungültig oder abgelaufen"
      when 429 then "YNAB: Anfragelimit erreicht (200 pro Stunde)"
      else          ["YNAB-Fehler #{status}", detail.presence].compact.join(": ")
      end)
    end
  end

  # Whether YNAB processed the request is unknown.
  class UnclearError < Exception
  end

  enum Failure
    Unclear # network, timeout, 5xx or an unreadable answer
    Unauthorized
    Forbidden
    NotFound
    RateLimited
    Rejected # another 4xx: concerns a single transaction
    Other    # not from YNAB (database, shutdown)

    def self.of(ex : Exception) : Failure
      case ex
      when UnclearError then Unclear
      when APIError
        case ex.status
        when 401   then Unauthorized
        when 403   then Forbidden
        when 404   then NotFound
        when 429   then RateLimited
        when 500.. then Unclear
        else            Rejected
        end
      else Other
      end
    end

    def aborts_run? : Bool
      !rejected?
    end
  end

  struct APIAccount
    include JSON::Serializable
    getter id : String
    getter name : String
    getter on_budget : Bool
    getter closed : Bool
    getter deleted : Bool
  end

  struct APIPlan
    include JSON::Serializable
    getter id : String
    getter name : String
    getter currency_format : NamedTuple(iso_code: String)?
    getter accounts = [] of APIAccount

    def currency : String?
      currency_format.try(&.[:iso_code])
    end
  end

  struct APICategory
    include JSON::Serializable
    getter id : String
    getter name : String
    getter hidden : Bool
    getter deleted : Bool
    getter internal = false
  end

  struct APICategoryGroup
    include JSON::Serializable
    getter id : String
    getter name : String
    getter hidden : Bool
    getter deleted : Bool
    getter internal = false
    getter categories : Array(APICategory)
  end

  struct APITxn
    include JSON::Serializable
    getter id : String
    getter memo : String?
    getter deleted : Bool
  end

  # Never an import_id: YNAB would merge imported transactions with the
  # reimbursement transfers of equal amount in "Geteilt".
  record SaveTxn, date : String, amount : Int64, payee_name : String, memo : String, id : String? = nil,
    account_id : String? = nil, category_id : String? = nil, cleared : String? = nil, approved : Bool? = nil do
    include JSON::Serializable
  end

  # An answer without the expected data is an unclear outcome, never an empty list.
  class Client
    alias Transactions = NamedTuple(transactions: Array(APITxn))

    def initialize(@base_url : String, @token : String, @http : OutboundHTTP)
    end

    def plans : Array(APIPlan)
      get(NamedTuple(plans: Array(APIPlan)), "/plans?include_accounts=true")[:plans]
    end

    def categories(plan_id : String) : Array(APICategoryGroup)
      get(NamedTuple(category_groups: Array(APICategoryGroup)), Client.plan_path(plan_id) + "/categories")[:category_groups]
    end

    def account(plan_id : String, account_id : String) : APIAccount
      get(NamedTuple(account: APIAccount), Client.plan_path(plan_id) + "/accounts/" + URI.encode_path_segment(account_id))[:account]
    end

    def create_transactions(plan_id : String, txns : Array(SaveTxn)) : Array(APITxn)
      save("POST", plan_id, txns)
    end

    def update_transactions(plan_id : String, txns : Array(SaveTxn)) : Array(APITxn)
      save("PATCH", plan_id, txns)
    end

    def delete_transaction(plan_id : String, txn_id : String) : Nil
      request("DELETE", Client.plan_path(plan_id) + "/transactions/" + URI.encode_path_segment(txn_id))
    end

    def account_transactions(plan_id : String, account_id : String) : Array(APITxn)
      get(Transactions, Client.plan_path(plan_id) + "/accounts/" + URI.encode_path_segment(account_id) + "/transactions")[:transactions]
    end

    protected def self.plan_path(plan_id : String) : String
      "/plans/" + URI.encode_path_segment(plan_id)
    end

    private def save(method : String, plan_id : String, txns : Array(SaveTxn)) : Array(APITxn)
      body = {transactions: txns}.to_json
      decode(Transactions, request(method, Client.plan_path(plan_id) + "/transactions", body))[:transactions]
    end

    private def get(type : T.class, path : String) : T forall T
      decode(type, request("GET", path))
    end

    private def decode(type : T.class, data : String) : T forall T
      NamedTuple(data: T).from_json(data)[:data]
    rescue ex : JSON::ParseException | JSON::SerializableError
      raise UnclearError.new("YNAB-Antwort unlesbar: #{ex.message}")
    end

    private def request(method : String, path : String, body : String? = nil) : String
      headers = HTTP::Headers{"Authorization" => "Bearer #{@token}", "Accept" => "application/json"}
      headers["Content-Type"] = "application/json" if body
      res = begin
        @http.request(method, @base_url + path, headers, body)
      rescue ex
        raise UnclearError.new("YNAB nicht erreichbar: #{ex.message}")
      end
      data = String.new(res.body)
      raise api_error(res.status, data, res.headers["Retry-After"]?) unless 200 <= res.status <= 299
      data
    end

    private def api_error(status : Int32, data : String, retry_after : String?) : APIError
      error = NamedTuple(error: NamedTuple(name: String?, detail: String?)).from_json(data)[:error] rescue nil
      wait = retry_after.try(&.strip.to_i64?).try { |seconds| seconds.seconds if seconds > 0 }
      APIError.new(status, error.try { |e| e[:detail].presence || e[:name] }, wait || Time::Span.zero)
    end
  end
end
