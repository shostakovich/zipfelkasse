require "http/client"
require "json"
require "uri"

module Zipfelkasse::YNAB
  # Budgets are called "plans" since API v1.79.
  DEFAULT_BASE_URL = "https://api.ynab.com/v1"

  MAX_PAYEE_LEN = 200
  MAX_MEMO_LEN  = 500
  HTTP_TIMEOUT  = 30.seconds
  MAX_BODY      = 64 << 20

  # An error response of the YNAB API; the message is shown on the settings
  # page, hence German.
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

  # Transport error, timeout or unreadable response: whether YNAB processed
  # the request is unknown.
  class UnclearError < Exception
  end

  def self.status_of(ex : Exception?) : Int32
    ex.is_a?(APIError) ? ex.status : 0
  end

  # Whether YNAB processed the request is unknown (network error, timeout,
  # 5xx).
  def self.uncertain?(ex : Exception) : Bool
    ex.is_a?(UnclearError) || status_of(ex) >= 500
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

  # A transaction to create (without id) or to update (with id). Empty
  # id/account_id/cleared and nil category_id/approved are left out;
  # payee_name and memo are always sent. Never an import_id: YNAB would merge
  # imported transactions with the reimbursement transfers of equal amount
  # in "Geteilt".
  record SaveTxn, id : String = "", account_id : String = "", date : String = "", amount : Int64 = 0_i64,
    payee_name : String = "", memo : String = "", category_id : String? = nil, cleared : String = "",
    approved : Bool? = nil do
    def to_json(j : JSON::Builder) : Nil
      j.object do
        j.field "id", id unless id.empty?
        j.field "account_id", account_id unless account_id.empty?
        j.field "date", date
        j.field "amount", amount
        j.field "payee_name", payee_name
        j.field "memo", memo
        category_id.try { |c| j.field "category_id", c }
        j.field "cleared", cleared unless cleared.empty?
        approved.try { |a| j.field "approved", a }
      end
    end
  end

  struct PlansData
    include JSON::Serializable
    getter plans : Array(APIPlan) = [] of APIPlan
  end

  struct CategoriesData
    include JSON::Serializable
    getter category_groups : Array(APICategoryGroup) = [] of APICategoryGroup
  end

  struct AccountData
    include JSON::Serializable
    getter account : APIAccount = APIAccount.from_json("{}")
  end

  struct TxnsData
    include JSON::Serializable
    getter transactions : Array(APITxn) = [] of APITxn
  end

  struct Envelope(T)
    include JSON::Serializable
    getter data : T?
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

  # Talks to the YNAB API on behalf of a token.
  class Client
    # Plan and account confirmed in this sync run (see Service#confirm_target).
    property? target_ok = false

    def initialize(@base_url : String, @token : String)
    end

    def plans : Array(APIPlan)
      get(PlansData, "/plans?include_accounts=true").try(&.plans) || [] of APIPlan
    end

    def categories(plan_id : String) : Array(APICategoryGroup)
      get(CategoriesData, Client.plan_path(plan_id) + "/categories").try(&.category_groups) || [] of APICategoryGroup
    end

    def account(plan_id : String, account_id : String) : APIAccount
      get(AccountData, Client.plan_path(plan_id) + "/accounts/" + URI.encode_path_segment(account_id)).try(&.account) ||
        APIAccount.from_json("{}")
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

    # The (non-deleted) transactions of an account from since on.
    def account_transactions(plan_id : String, account_id : String, since : Time) : Array(APITxn)
      path = Client.plan_path(plan_id) + "/accounts/" + URI.encode_path_segment(account_id) +
             "/transactions?since_date=" + since.to_s("%Y-%m-%d")
      get(TxnsData, path).try(&.transactions) || [] of APITxn
    end

    protected def self.plan_path(plan_id : String) : String
      "/plans/" + URI.encode_path_segment(plan_id)
    end

    private def save(method : String, plan_id : String, txns : Array(SaveTxn)) : Array(APITxn)
      body = {transactions: txns}.to_json
      decode(TxnsData, request(method, Client.plan_path(plan_id) + "/transactions", body)).try(&.transactions) ||
        [] of APITxn
    end

    private def get(type : T.class, path : String) : T? forall T
      decode(type, request("GET", path))
    end

    private def decode(type : T.class, data : String) : T? forall T
      Envelope(T).from_json(data).data
    rescue ex : JSON::ParseException | JSON::SerializableError
      raise UnclearError.new("YNAB-Antwort unlesbar: #{ex.message}")
    end

    # The error messages end up on the settings page, hence German.
    private def request(method : String, path : String, body : String? = nil) : String
      uri = URI.parse(@base_url + path)
      headers = HTTP::Headers{"Authorization" => "Bearer #{@token}", "Accept" => "application/json"}
      headers["Content-Type"] = "application/json" if body
      client = HTTP::Client.new(uri)
      client.connect_timeout = HTTP_TIMEOUT
      client.read_timeout = HTTP_TIMEOUT
      client.write_timeout = HTTP_TIMEOUT
      status, retry_after, data = 0, nil.as(String?), ""
      begin
        client.exec(method, uri.request_target, headers, body) do |res|
          status, retry_after = res.status_code, res.headers["Retry-After"]?
          data = begin
            read_limited(res.body_io)
          rescue ex
            raise UnclearError.new("YNAB-Antwort unvollständig: #{ex.message}")
          end
        end
      rescue ex : UnclearError
        raise ex
      rescue ex
        raise UnclearError.new("YNAB nicht erreichbar: #{ex.message}")
      ensure
        client.close
      end
      raise api_error(status, data, retry_after) unless 200 <= status <= 299
      data
    end

    private def read_limited(io : IO) : String
      buf = IO::Memory.new
      IO.copy(io, buf, MAX_BODY)
      buf.to_s
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
