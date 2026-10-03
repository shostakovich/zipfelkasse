module Zipfelkasse::MCP
  def self.eur(cents : Int64) : String
    Domain.format_decimal(cents, 2, '.')
  end

  def self.eur?(cents : Int64?) : String?
    cents.try { |c| eur(c) }
  end

  def self.money(minor : Int64, currency : String) : String
    currency = currency.strip.upcase
    "#{Domain.format_decimal(minor, Domain.currency_decimals(currency), '.')} #{currency}"
  end

  # RFC 3339 in t's zone ("Z" for any zero offset); Time#to_rfc3339 would
  # convert to UTC.
  def self.rfc3339(t : Time) : String
    t.offset == 0 ? t.to_s("%Y-%m-%dT%H:%M:%SZ") : t.to_s("%Y-%m-%dT%H:%M:%S%:z")
  end

  def self.min_time(t : Time?, fallback : Time) : Time
    t.nil? || t > fallback ? fallback : t
  end

  def self.given(value : String?) : String?
    value.try(&.strip.presence)
  end

  def self.parse_date_arg(name : String, value : String?) : Time?
    value = given(value) || return
    Domain.parse_date(value)
  rescue Domain::ValidationError
    raise invalid("Invalid date for #{name}: #{value.inspect} (expected YYYY-MM-DD).")
  end

  def self.parse_range(from_arg : String?, to_arg : String?) : {Time?, Time?}
    from = parse_date_arg("from", from_arg)
    to = parse_date_arg("to", to_arg)
    if from && to && to < from
      raise invalid(%("to" (#{Store.format_date(to)}) is before "from" (#{Store.format_date(from)}).))
    end
    {from, to}
  end

  def self.describe_range(from : Time?, to : Time?) : String
    if from && to
      "#{Store.format_date(from)} to #{Store.format_date(to)}"
    elsif from
      "from #{Store.format_date(from)}"
    elsif to
      "until #{Store.format_date(to)}"
    else
      "all time"
    end
  end

  def self.overview_text(o : Store::DataOverview) : String
    String.build do |b|
      b << "Data overview: "
      first, last = o.first_date, o.last_date
      if first && last
        b << o.expenses << " expenses and " << o.reimbursements << " reimbursements dated " << Store.format_date(first) << " to " << Store.format_date(last) << ". "
        pct = o.expenses > 0 ? o.without_category.to_f * 100 / o.expenses : 0.0
        b << o.without_category << " of the expenses (" << "%.1f" % pct << "%) have no category."
      else
        b << "there are no expenses yet."
      end
      b << " Values of activity.action: " << o.activity_actions.join(", ") << '.' unless o.activity_actions.empty?
    end
  end

  def self.find_named(items : Array(T), kind : String, name : String) : T forall T
    name = name.strip
    items.find(&.name.compare(name, case_insensitive: true).zero?) ||
      raise invalid("Unknown #{kind} #{name.inspect}. Available: #{items.join(", ", &.name)}.")
  end

  def self.limit(value : Int64?, default : Int32) : Int32
    return default unless value
    raise invalid("limit must be between 1 and #{SQLSandbox::MAX_ROWS}.") unless 1 <= value <= SQLSandbox::MAX_ROWS
    value.to_i
  end

  def self.amount_cents(name : String, euros : Float64?) : Int64?
    return unless euros
    raise invalid("#{name} must be an amount in euros of at least 0.") if euros < 0 || euros.nan? || euros > 1e12
    (euros * 100).round(:ties_away).to_i64
  end
end
