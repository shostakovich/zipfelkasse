require "json"

module Zipfelkasse::MCP
  def self.invalid(message : String) : Domain::ValidationError
    Domain::ValidationError.new(message)
  end

  module Args
    macro included
      include JSON::Serializable
      include JSON::Serializable::Strict
    end
  end

  def self.args(type : T.class, raw : String?) : T forall T
    T.from_json(raw || "{}")
  rescue ex : JSON::Error
    raise invalid("Invalid arguments: #{reason(ex)}")
  end

  module TextList
    def self.from_json(pull : JSON::PullParser) : Array(String)
      return [pull.read_string] if pull.kind.string?
      list = [] of String
      pull.read_array { pull.read_string_or_null.try { |text| list << text } }
      list
    end
  end

  # An amount as a string or a JSON number (as written); parsed once the currency and its decimals are known.
  module AmountText
    def self.from_json(pull : JSON::PullParser) : String
      case pull.kind
      when .string?       then pull.read_string
      when .int?, .float? then pull.read_raw
      else                     pull.raise "Expected a string or a number"
      end
    end
  end

  module Weights
    def self.from_json(pull : JSON::PullParser) : Hash(String, String)
      weights = {} of String => String
      pull.read_object { |name| weights[name] = AmountText.from_json(pull) }
      weights
    end
  end

  enum ReimbursementFilter
    Exclude
    Include
    Only
  end

  enum Detail
    Compact
    Full
  end

  enum Comparison
    PreviousYear
  end

  struct NoArgs
    include Args
  end

  struct HistoryArgs
    include Args
    getter interval : Domain::PeriodUnit?
    getter from : String?
    getter to : String?
    getter person : String?
  end

  struct SearchArgs
    include Args
    getter from : String?
    getter to : String?
    getter category : String?
    getter person : String?
    getter paid_by : String?
    getter involved : String?
    @[JSON::Field(converter: Zipfelkasse::MCP::TextList)]
    getter text = [] of String
    getter min_amount : Float64?
    getter max_amount : Float64?
    getter reimbursements : ReimbursementFilter?
    getter sort : Store::ExpenseSort?
    getter detail : Detail?
    getter limit : Int64?
  end

  struct StatisticsArgs
    include Args
    getter group_by : Store::StatsGroup
    getter from : String?
    getter to : String?
    getter share_of : String?
    getter category : String?
    @[JSON::Field(converter: Zipfelkasse::MCP::TextList)]
    getter text = [] of String
    getter compare : Comparison?
    getter limit : Int64?
  end

  struct ActivityArgs
    include Args
    getter from : String?
    getter to : String?
    getter person : String?
    getter action : Store::Action?
    getter expense_id : Int64?
    getter before_id : Int64?
    getter limit : Int64?
  end

  struct SQLArgs
    include Args
    getter query : String?
  end

  module MoneyArgs
    @[JSON::Field(converter: Zipfelkasse::MCP::AmountText)]
    getter amount : String?
    getter currency : String?
    getter fx_rate : Float64?
  end

  struct ExpenseArgs
    include Args
    include MoneyArgs
    getter title : String?
    getter date : String?
    getter paid_by : String?
    getter category : String?
    getter split : Domain::SplitMode?
    getter participants = [] of String
    @[JSON::Field(converter: Zipfelkasse::MCP::Weights)]
    getter weights = {} of String => String
    getter notes : String?
    getter allow_duplicate = false
  end

  struct ReimbursementArgs
    include Args
    include MoneyArgs
    getter from : String?
    getter to : String?
    getter date : String?
    getter notes : String?
    getter allow_duplicate = false
  end
end
