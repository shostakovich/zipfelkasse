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
    getter id : String
    getter name : String
    getter detail : String
    getter retry_after : Time::Span # on 429, if given

    def initialize(@status, @id = "", @name = "", @detail = "", @retry_after = Time::Span.zero)
      super(APIError.text(@status, @name, @detail))
    end

    protected def self.text(status : Int32, name : String, detail : String) : String
      case status
      when 401 then return "YNAB: Token ungültig oder abgelaufen"
      when 429 then return "YNAB: Anfragelimit erreicht (200 pro Stunde)"
      end
      msg = "YNAB-Fehler #{status}"
      if !detail.empty?
        msg += ": " + detail
      elsif !name.empty?
        msg += ": " + name
      end
      msg
    end
  end

  class UnclearError < Exception
  end

  enum Failure
    Unclear # whether YNAB processed the request is unknown (network, timeout, 5xx, unreadable answer)
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
    getter id : String = ""
    getter name : String = ""
    getter type : String = ""
    getter on_budget : Bool = false
    getter closed : Bool = false
    getter deleted : Bool = false
  end

  struct APICurrencyFormat
    include JSON::Serializable
    getter iso_code : String = ""
  end

  struct APIPlan
    include JSON::Serializable
    getter id : String = ""
    getter name : String = ""
    getter currency_format : APICurrencyFormat? = nil
    getter accounts : Array(APIAccount) = [] of APIAccount

    def currency : String
      currency_format.try(&.iso_code) || ""
    end
  end

  struct APICategory
    include JSON::Serializable
    getter id : String = ""
    getter name : String = ""
    getter hidden : Bool = false
    getter internal : Bool = false
    getter deleted : Bool = false
  end

  struct APICategoryGroup
    include JSON::Serializable
    getter id : String = ""
    getter name : String = ""
    getter hidden : Bool = false
    getter internal : Bool = false
    getter deleted : Bool = false
    getter categories : Array(APICategory) = [] of APICategory
  end

  struct APITxn
    include JSON::Serializable
    getter id : String = ""
    getter date : String = ""
    getter amount : Int64 = 0
    getter memo : String? = nil
    getter payee_name : String? = nil
    getter category_id : String? = nil
    getter account_id : String = ""
    getter cleared : String = ""
    getter approved : Bool = false
    getter deleted : Bool = false
  end

  # Never an import_id: YNAB would merge imported transactions with the
  # reimbursement transfers of equal amount in "Geteilt".
  record SaveTxn, date : String, amount : Int64, payee_name : String, memo : String, id : String? = nil,
    account_id : String? = nil, category_id : String? = nil, cleared : String? = nil, approved : Bool? = nil do
    include JSON::Serializable
  end

  struct PlansData
    include JSON::Serializable
    getter plans : Array(APIPlan)
  end

  struct CategoriesData
    include JSON::Serializable
    getter category_groups : Array(APICategoryGroup)
  end

  struct AccountData
    include JSON::Serializable
    getter account : APIAccount
  end

  struct TxnsData
    include JSON::Serializable
    getter transactions : Array(APITxn)
  end

  struct Envelope(T)
    include JSON::Serializable
    getter data : T
  end

  struct ErrorBody
    include JSON::Serializable
    getter error : ErrorFields = ErrorFields.from_json("{}")
  end

  struct ErrorFields
    include JSON::Serializable
    getter id : String = ""
    getter name : String = ""
    getter detail : String = ""
  end

  # Talks to the YNAB API on behalf of a token. An answer without the
  # expected data is an unclear outcome, never an empty list.
  class Client
    def initialize(@base_url : String, @token : String, @http : OutboundHTTP)
    end

    def plans : Array(APIPlan)
      get(PlansData, "/plans?include_accounts=true").plans
    end

    def categories(plan_id : String) : Array(APICategoryGroup)
      get(CategoriesData, Client.plan_path(plan_id) + "/categories").category_groups
    end

    def account(plan_id : String, account_id : String) : APIAccount
      get(AccountData, Client.plan_path(plan_id) + "/accounts/" + URI.encode_path_segment(account_id)).account
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
      get(TxnsData, Client.plan_path(plan_id) + "/accounts/" + URI.encode_path_segment(account_id) + "/transactions").transactions
    end

    protected def self.plan_path(plan_id : String) : String
      "/plans/" + URI.encode_path_segment(plan_id)
    end

    private def save(method : String, plan_id : String, txns : Array(SaveTxn)) : Array(APITxn)
      body = {transactions: txns}.to_json
      decode(TxnsData, request(method, Client.plan_path(plan_id) + "/transactions", body)).transactions
    end

    private def get(type : T.class, path : String) : T forall T
      decode(type, request("GET", path))
    end

    private def decode(type : T.class, data : String) : T forall T
      Envelope(T).from_json(data).data
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
      fields = begin
        ErrorBody.from_json(data).error
      rescue JSON::ParseException | JSON::SerializableError
        ErrorFields.from_json("{}")
      end
      wait = Time::Span.zero
      if (s = retry_after.try(&.strip.to_i64?)) && s > 0
        wait = s.seconds
      end
      APIError.new(status, fields.id, fields.name, fields.detail, wait)
    end
  end
end
