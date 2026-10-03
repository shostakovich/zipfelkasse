require "json"

module Zipfelkasse
  class Store
    # This recurrence already has an expense on this date.
    class RecurringExists < Exception
      def initialize(message = "expense for this occurrence already exists")
        super
      end
    end

    # The recurrence was paused, deleted or advanced since it was read.
    class RecurringChanged < Exception
      def initialize(message = "recurring rule was paused, deleted or advanced meanwhile")
        super
      end
    end

    class NoInstance < Exception
      def initialize(message = "recurring rule has no expense")
        super
      end
    end

    # JSON of a calendar date; nil is stored as 0001-01-01T00:00:00Z, which
    # older rows contain.
    module DateConverter
      ZERO = Time.utc(1, 1, 1)

      def self.to_json(value : Time?, json : JSON::Builder) : Nil
        json.string((value || ZERO).to_rfc3339)
      end

      def self.from_json(pull : JSON::PullParser) : Time?
        return pull.read_null if pull.kind.null?
        t = Time.parse_rfc3339(pull.read_string)
        t == ZERO ? nil : Domain.date_of(t)
      end
    end

    module SplitModeConverter
      def self.to_json(value : Domain::SplitMode, json : JSON::Builder) : Nil
        json.string(value.value)
      end

      def self.from_json(pull : JSON::PullParser) : Domain::SplitMode
        Domain::SplitMode.new(pull.read_string)
      end
    end

    # An expense as entered (or as a recurrence template, stored as JSON).
    # The store computes the shares from split_mode, amounts and parts. For
    # SPLIT_AMOUNT the weights are amounts in the smallest unit of
    # original_currency.
    #
    # Foreign currency: original_currency "" or "EUR" means none; the store
    # then sets original_amount_minor = amount_cents, fx_rate = 1, fx_source
    # = "". Otherwise the store computes amount_cents itself.
    struct ExpenseInput
      include JSON::Serializable

      property title : String = ""
      @[JSON::Field(converter: Zipfelkasse::Store::DateConverter, ignore_serialize: true)]
      property date : Time? = nil # calendar date
      property category_id : Int64 = 0_i64 # 0 = no category
      property paid_by : Int64 = 0_i64
      property notes : String = ""
      # Reimbursement: paid_by pays parts[0].
      @[JSON::Field(key: "is_reimbursement")]
      property? reimbursement : Bool = false
      @[JSON::Field(converter: Zipfelkasse::Store::SplitModeConverter)]
      property split_mode : Domain::SplitMode = Domain::SPLIT_EQUAL
      property amount_cents : Int64 = 0_i64 # always EUR
      property parts : Array(Domain::Part) = [] of Domain::Part
      property original_amount_minor : Int64 = 0_i64
      property original_currency : String = ""
      property fx_rate : Float64 = 0.0
      property fx_source : String = ""
      # Set only on creation of a recurrence's instance.
      property recurring_id : Int64 = 0_i64

      def initialize(*, @title = "", @date = nil, @category_id = 0_i64, @paid_by = 0_i64, @notes = "",
                     @reimbursement = false, @split_mode = Domain::SPLIT_EQUAL, @amount_cents = 0_i64,
                     @parts = [] of Domain::Part, @original_amount_minor = 0_i64, @original_currency = "",
                     @fx_rate = 0.0, @fx_source = "", @recurring_id = 0_i64)
      end

      # The converter is not called for nil, but templates need the zero date.
      protected def on_to_json(json : JSON::Builder)
        json.field("date") { DateConverter.to_json(@date, json) }
      end
    end

    # A stored expense. `input` is complete (parts from the stored weights),
    # so it can be passed straight back to update_expense.
    struct Expense
      getter id : Int64
      property input : ExpenseInput
      property shares : Array(Domain::Share) # sorted by participant_id
      property category_name : String       # "" without category
      property paid_by_name : String
      property created_at : Time?
      property updated_at : Time?
      property deleted_at : Time?

      delegate title, category_id, paid_by, notes, reimbursement?, split_mode, amount_cents, parts,
        original_amount_minor, original_currency, fx_rate, fx_source, recurring_id, to: @input

      def initialize(@id, @input, @shares = [] of Domain::Share, @category_name = "", @paid_by_name = "",
                     @created_at = nil, @updated_at = nil, @deleted_at = nil)
      end

      def date : Time
        @input.date || raise "expense #{id} has no date"
      end

      def deleted? : Bool
        !deleted_at.nil?
      end

      def foreign? : Bool
        !Domain.eur?(original_currency)
      end

      # Cents of participant_id's share, 0 if not involved.
      def share_of(participant_id : Int64) : Int64
        shares.find(&.participant_id.==(participant_id)).try(&.amount_cents) || 0_i64
      end
    end

    # Narrows list_expenses; defaults mean "no filter".
    struct ExpenseFilter
      property text : String = ""                   # substring of title or notes, folded
      property any_text : Array(String) = [] of String # one of them suffices (together with text)
      property category_id : Int64 = 0_i64
      property? without_category : Bool = false # category_id is then ignored
      property participant_id : Int64 = 0_i64   # paid or is involved
      property paid_by : Int64 = 0_i64
      property involved_id : Int64 = 0_i64
      property min_cents : Int64 = 0_i64 # 0 = open
      property max_cents : Int64 = 0_i64 # 0 = open
      property from : Time? = nil        # inclusive
      property to : Time? = nil          # inclusive
      property sort : String = ""        # SORT_*, "" = SORT_DATE_DESC
      property limit : Int32 = 0         # 0 = all
      property offset : Int32 = 0

      def initialize(*, @text = "", @any_text = [] of String, @category_id = 0_i64, @without_category = false,
                     @participant_id = 0_i64, @paid_by = 0_i64, @involved_id = 0_i64, @min_cents = 0_i64,
                     @max_cents = 0_i64, @from = nil, @to = nil, @sort = "", @limit = 0, @offset = 0)
      end
    end

    # Ties are broken newest first.
    SORT_DATE_DESC   = "date_desc"
    SORT_DATE_ASC    = "date_asc"
    SORT_AMOUNT_DESC = "amount_desc"
    SORT_AMOUNT_ASC  = "amount_asc"

    # Categories are only ever archived, never deleted.
    record Category, id : Int64, name : String, position : Int64, archived_at : Time? do
      def archived? : Bool
        !archived_at.nil?
      end
    end

    record DatedEntry, date : Time, entry : Domain::Entry
  end
end
