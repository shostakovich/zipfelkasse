require "json"

module Zipfelkasse::MCP
  def self.invalid(message : String) : Domain::ValidationError
    Domain::ValidationError.new(message)
  end

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
              \{% if t < Enum %}
                "one of " + \{{t}}.values.join(", ", &.to_s.underscore)
              \{% else %}
                \{{t == String ? "a string" : t <= Int ? "an integer" : t <= Float ? "a number" : t == Bool ? "true or false" : t <= Array ? "a list of strings" : "an object"}}
              \{% end %}
          \{% end %}
          else "something else"
          end
        \{% end %}
      end
    end
  end

  def self.decode_error(type : T.class, ex : JSON::SerializableError, whole : String) : String forall T
    field = ex.attribute || return "#{whole} must be an object."
    "#{field} must be #{T.expected(field)}."
  end

  # Tool arguments: unknown fields are errors, null leaves the default.
  module Args
    macro included
      include Decodable

      protected def on_unknown_json_attribute(pull, key, key_location)
        raise MCP.invalid(%(Invalid arguments: unknown field #{key.inspect}.))
      end
    end
  end

  def self.args(type : T.class, raw : String?) : T forall T
    T.from_json(raw || "{}")
  rescue ex : JSON::SerializableError
    raise invalid("Invalid arguments: #{decode_error(T, ex, "arguments")}")
  end

  module TextList
    def self.from_json(pull : JSON::PullParser) : Array(String)
      not_text = MCP.invalid("Invalid arguments: must be a string or a list of strings")
      return [pull.read_string] if pull.kind.string?
      raise not_text unless pull.kind.begin_array?
      list = [] of String
      pull.read_array do
        case pull.kind
        when .string? then list << pull.read_string
        when .null?   then pull.read_null
        else               raise not_text
        end
      end
      list
    end
  end

  # An amount given as a string or a JSON number (as written); parsed later,
  # once the currency (and its decimals) is known.
  module AmountText
    def self.from_json(pull : JSON::PullParser) : String
      case pull.kind
      when .string?       then pull.read_string
      when .int?, .float? then pull.read_raw
      else                     raise MCP.invalid("Invalid arguments: must be a string or a number")
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

  module Choice(T)
    def self.from_json(pull : JSON::PullParser) : T
      location = pull.location
      text = pull.read_string
      T.parse?(text.strip) || raise JSON::ParseException.new("Unknown #{T} #{text.inspect}", *location)
    end
  end

  def self.one_of(name : String, type : T.class) : Domain::ValidationError forall T
    invalid("Invalid arguments: #{name} must be one of #{type.values.join(", ", &.to_s.underscore)}.")
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
    @[JSON::Field(converter: Zipfelkasse::MCP::Choice(Domain::PeriodUnit))]
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
    @[JSON::Field(converter: Zipfelkasse::MCP::Choice(ReimbursementFilter))]
    getter reimbursements : ReimbursementFilter?
    @[JSON::Field(converter: Zipfelkasse::MCP::Choice(Store::ExpenseSort))]
    getter sort : Store::ExpenseSort?
    @[JSON::Field(converter: Zipfelkasse::MCP::Choice(Detail))]
    getter detail : Detail?
    getter limit : Int64?
  end

  struct StatisticsArgs
    include Args
    @[JSON::Field(converter: Zipfelkasse::MCP::Choice(Store::StatsGroup))]
    getter group_by : Store::StatsGroup?
    getter from : String?
    getter to : String?
    getter share_of : String?
    getter category : String?
    @[JSON::Field(converter: Zipfelkasse::MCP::TextList)]
    getter text = [] of String
    @[JSON::Field(converter: Zipfelkasse::MCP::Choice(Comparison))]
    getter compare : Comparison?
    getter limit : Int64?
  end

  struct ActivityArgs
    include Args
    getter from : String?
    getter to : String?
    getter person : String?
    @[JSON::Field(converter: Zipfelkasse::MCP::Choice(Store::Action))]
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
    @[JSON::Field(converter: Zipfelkasse::MCP::Choice(Domain::SplitMode))]
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
