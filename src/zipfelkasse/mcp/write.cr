# The write tools create_expense and create_reimbursement. They only add
# entries – nothing is changed or deleted. The person who paid counts as the
# author in the activity log (MCP has no logged-in user).
module Zipfelkasse::MCP
  # As in the expense form.
  REIMBURSEMENT_TITLE = "Rückzahlung"

  # Neither read-only nor idempotent, so clients ask before running them.
  WRITE = {"readOnlyHint" => false, "destructiveHint" => false, "idempotentHint" => false, "openWorldHint" => false}

  # An amount given as a string or a JSON number (as written); parsed later,
  # once the currency (and its decimals) is known.
  module AmountText
    def self.from_json(pull : JSON::PullParser) : String
      case pull.kind
      when .string?       then pull.read_string
      when .int?, .float? then pull.read_raw
      when .null?         then pull.read_null || ""
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

  module MoneyArgs
    @[JSON::Field(converter: Zipfelkasse::MCP::AmountText)]
    getter amount = ""
    getter currency = ""
    getter fx_rate : Float64? = nil
  end

  struct ExpenseArgs
    include Args
    include MoneyArgs
    getter title = "", date = "", paid_by = "", category = "", split = ""
    getter participants = [] of String
    @[JSON::Field(converter: Zipfelkasse::MCP::Weights)]
    getter weights = {} of String => String
    getter notes = ""
    getter allow_duplicate = false
  end

  struct ReimbursementArgs
    include Args
    include MoneyArgs
    getter from = "", to = "", date = "", notes = ""
    getter allow_duplicate = false
  end

  class DecimalError < Exception
  end

  # A non-negative number with a dot as decimal separator and at most
  # decimals decimal places (superfluous zeros are fine) in the smallest
  # unit: ("23.4", 2) → 2340. Unlike Domain.parse_minor it accepts no
  # thousands separators, so "1.234" is never 1234.
  def self.parse_decimal(s : String, decimals : Int32) : Int64
    whole, _, frac = s.strip.partition('.')
    frac = frac.rstrip('0')
    digits = ->(v : String) { v.each_char.all?(&.ascii_number?) }
    if whole.empty? || !digits.call(whole) || !digits.call(frac)
      raise DecimalError.new("use digits with a dot as decimal separator and no thousands separator, e.g. 1234.50")
    elsif frac.size > decimals
      raise DecimalError.new(decimals == 0 ? "must be a whole number" : "at most #{decimals} decimal places")
    elsif whole.size > 15
      raise DecimalError.new("too large")
    end
    (whole + frac + "0" * (decimals - frac.size)).to_i64
  end

  # Resolves a name to a person who is not archived.
  def self.active_person(ps : Array(Store::Participant), arg : String, name : String) : Store::Participant
    name = name.strip
    raise invalid("Parameter #{arg} is missing.") if name.empty?
    names = [] of String
    ps.each do |p|
      same = p.name.compare(name, case_insensitive: true).zero?
      if p.archived?
        raise invalid("#{p.name} is archived and cannot take part in new entries.") if same
      else
        return p if same
        names << p.name
      end
    end
    raise invalid("Unknown person #{name.inspect} in #{arg}. Available: #{names.join(", ")}.")
  end

  # Participants (equal) or weights (other modes) as parts; without either,
  # equal goes to all active people.
  def self.split_args(ps : Array(Store::Participant), mode : Domain::SplitMode, currency : String,
                      participants : Array(String), weights : Hash(String, String)) : Array(Domain::Part)
    parts = [] of Domain::Part
    seen = Set(Int64).new
    add = ->(name : String, weight : Int64) do
      p = active_person(ps, "the split", name)
      raise invalid("#{p.name} appears twice in the split.") unless seen.add?(p.id)
      parts << Domain::Part.new(p.id, weight)
    end
    if mode == Domain::SPLIT_EQUAL
      unless weights.empty?
        raise invalid("weights are only for split=shares, percent or amount; use participants for an equal split.")
      end
      return ps.reject(&.archived?).map { |p| Domain::Part.new(p.id) } if participants.empty?
      participants.each { |name| add.call(name, 0_i64) }
      return parts
    end
    raise invalid("With split=#{mode}, weights name the participants; leave participants out.") unless participants.empty?
    raise invalid("split=#{mode} needs weights (person name → value).") if weights.empty?
    weights.keys.sort!.each do |name|
      w = begin
        parse_decimal(weights[name], Domain.weight_decimals(mode, currency))
      rescue ex : DecimalError
        raise invalid("Invalid value #{weights[name].inspect} for #{name} in weights: #{ex.message}.")
      end
      add.call(name, w)
    end
    parts
  end

  class Server
    private def register_write_tools : Nil
      amount_prop = {"type" => ["string", "number"], "description" => %(Amount in currency (default EUR) with a dot as decimal separator, e.g. "23.40".)}
      currency_prop = {"type" => "string", "description" => "ISO currency code, e.g. USD. Default EUR."}
      rate_prop = {"type" => "number", "exclusiveMinimum" => 0,
                   "description" => "Only for a foreign currency: units of that currency per 1 EUR. Default: the ECB reference rate of the date."}
      dup_prop = ->(same : String) do
        {"type" => "boolean", "description" => "Create it even if an entry with the same date, payer, amount and #{same} exists. Only set after asking the user."}
      end

      add("create_expense", "Create expense",
        "Creates an expense, as if the payer had entered it in the app. Ask the user before calling it if anything is unclear " \
        "(amount, payer, who takes part); then tell them what was created. Without participants and weights, the amount is " \
        "split equally among all active people. An entry with the same date, payer, amount and title is refused unless allow_duplicate is set. " \
        "Settlement payments between people are not expenses: use create_reimbursement for them.",
        Server.object_schema({
          "title"    => {"type" => "string", "description" => %(What was bought, e.g. "Rewe" or "Pizza" (usually German, like the existing titles).)},
          "amount"   => amount_prop,
          "currency" => currency_prop,
          "fx_rate"  => rate_prop,
          "date"     => Server.date_prop("Date of the expense. Default today."),
          "paid_by"  => {"type" => "string", "description" => "Name of the person who paid."},
          "category" => {"type" => "string", "description" => "Category name (case-insensitive). Empty = no category."},
          "split"    => {"type" => "string", "enum" => Domain::SPLIT_MODES.map(&.value),
                      "description" => "equal (default): evenly among participants. shares, percent, amount: by the values in weights."},
          "participants" => {"type" => "array", "items" => {"type" => "string"},
                             "description" => "Only for split=equal: names of the people the expense is for. Default: all active people."},
          "weights" => {"type" => "object", "additionalProperties" => {"type" => ["string", "number"]},
                        "description" => %(For shares, percent and amount: person name → value, e.g. {"Anna": 2, "Ben": 1} (shares), {"Anna": 70, "Ben": 30} (percent, sum 100) ) +
                                         %(or {"Anna": "15.00", "Ben": "8.40"} (amounts in currency, sum = amount). These people are the participants.)},
          "notes"           => {"type" => "string", "description" => "Optional note."},
          "allow_duplicate" => dup_prop.call("title"),
        }, ["title", "amount", "paid_by"]), WRITE) { |raw| create_expense(raw) }

      add("create_reimbursement", "Create reimbursement",
        "Records a settlement payment: from paid amount to to (e.g. a bank transfer to settle up). It changes the balances, but is not an expense. " \
        "An entry with the same date, payer, amount and recipient is refused unless allow_duplicate is set.",
        Server.object_schema({
          "from"            => {"type" => "string", "description" => "Name of the person who paid the money."},
          "to"              => {"type" => "string", "description" => "Name of the person who received it."},
          "amount"          => amount_prop,
          "currency"        => currency_prop,
          "fx_rate"         => rate_prop,
          "date"            => Server.date_prop("Date of the payment. Default today."),
          "notes"           => {"type" => "string", "description" => "Optional note."},
          "allow_duplicate" => dup_prop.call("recipient"),
        }, ["from", "to", "amount"]), WRITE) { |raw| create_reimbursement(raw) }
    end

    private def create_expense(raw : String?) : String
      a = MCP.args(ExpenseArgs, raw)
      title = a.title.strip
      mode = Domain::SplitMode.new(MCP.trim_or(a.split, Domain::SPLIT_EQUAL.value))
      raise MCP.invalid("Parameter title is missing.") if title.empty?
      raise MCP.invalid("split must be one of equal, shares, percent, amount.") unless mode.valid?
      date = date_or_today(a.date)
      input = set_money(Store::ExpenseInput.new(title: title, notes: a.notes, split_mode: mode, date: date), a, date)
      ps = participants
      payer = MCP.active_person(ps, "paid_by", a.paid_by)
      input.paid_by = payer.id
      unless a.category.blank?
        c = find_category(a.category)
        raise MCP.invalid("Category #{c.name} is archived.") if c.archived?
        input.category_id = c.id
      end
      input.parts = MCP.split_args(ps, mode, input.original_currency.presence || "EUR", a.participants, a.weights)
      create(input, date, payer, ps, a.allow_duplicate)
    end

    private def create_reimbursement(raw : String?) : String
      a = MCP.args(ReimbursementArgs, raw)
      date = date_or_today(a.date)
      input = Store::ExpenseInput.new(title: REIMBURSEMENT_TITLE, notes: a.notes, reimbursement: true, date: date)
      input = set_money(input, a, date)
      ps = participants
      from = MCP.active_person(ps, "from", a.from)
      to = MCP.active_person(ps, "to", a.to)
      raise MCP.invalid("from and to must be different people.") if from.id == to.id
      input.paid_by = from.id
      input.parts = [Domain::Part.new(to.id)]
      create(input, date, from, ps, a.allow_duplicate)
    end

    # Empty = today in the server time zone.
    private def date_or_today(v : String) : Time
      MCP.parse_date_arg("date", v) || today
    end

    # Amount, currency and rate; a foreign currency without fx_rate gets the
    # ECB rate of the date.
    private def set_money(input : Store::ExpenseInput, a : MoneyArgs, date : Time) : Store::ExpenseInput
      currency = a.currency
      cur = MCP.trim_or(currency, "EUR").upcase
      unless Domain.valid_currency_code?(cur)
        raise MCP.invalid("currency must be a three-letter ISO code such as USD, not #{currency.inspect}.")
      end
      amount = a.amount
      raise MCP.invalid("Parameter amount is missing.") if amount.blank?
      minor = begin
        MCP.parse_decimal(amount, Domain.currency_decimals(cur))
      rescue ex : DecimalError
        raise MCP.invalid("Invalid amount #{amount.inspect} for #{cur}: #{ex.message}")
      end
      raise MCP.invalid("amount must be greater than 0.") if minor <= 0
      rate = a.fx_rate
      if cur == "EUR"
        raise MCP.invalid("fx_rate is only for foreign currencies.") if rate
        input.amount_cents = minor
        return input
      end
      input.original_amount_minor, input.original_currency = minor, cur
      if rate
        raise MCP.invalid("fx_rate must be greater than 0.") if rate <= 0
        input.fx_rate, input.fx_source = rate, Domain::FX_SOURCE_MANUAL
        return input
      end
      no_rate = MCP.invalid("There is no exchange rate for #{cur} on #{MCP.ymd(date)}. Ask the user for the rate and pass it as fx_rate.")
      fx = @d.fx || raise no_rate
      r = begin
        fx.rate(cur, date)
      rescue ex
        @log.info("mcp: rate not available", currency: cur, date: MCP.ymd(date), err: ex)
        raise no_rate
      end
      raise no_rate unless r.rate > 0
      input.fx_rate, input.fx_source = r.rate, r.source.presence || Domain::FX_SOURCE_ECB
      input
    end

    # Stores input with the payer as author, unless an identical entry exists
    # (same date, payer, amount in euros, kind and title or recipient).
    private def create(input : Store::ExpenseInput, date : Time, payer : Store::Participant, ps : Array(Store::Participant),
                       allow_duplicate : Bool) : String
      cents = input.original_currency.empty? ? input.amount_cents : Domain.to_eur_cents(input.original_amount_minor, input.original_currency, input.fx_rate)
      if !allow_duplicate && cents > 0
        same = @d.store.list_expenses(Store::ExpenseFilter.new(from: date, to: date, paid_by: input.paid_by, min_cents: cents, max_cents: cents))
        same.each do |e|
          next if e.reimbursement? != input.reimbursement?
          duplicate = input.reimbursement? ? e.share_of(input.parts[0].participant_id) != 0 : Store.fold(e.title) == Store.fold(input.title)
          next unless duplicate
          raise MCP.invalid("This looks like a duplicate of entry #{e.id} (#{MCP.ymd(e.date)}, #{e.title}, #{MCP.eur(e.amount_cents)} EUR, paid by #{e.paid_by_name}). " \
                            "Ask the user; if it really is a second one, call again with allow_duplicate=true.")
        end
      end
      id = begin
        @d.store.create_expense(payer.id, input)
      rescue ex : Domain::ValidationError
        # The app's own rules (e.g. sum of the split) answer in German.
        raise MCP.invalid("The app refused the entry (message in German): #{ex.message}")
      end
      @log.info("mcp: entry created", id: id, reimbursement: input.reimbursement?)
      e = @d.store.get_expense(id)
      names = ps.to_h { |p| {p.id, p.name} }
      JSON.build do |j|
        j.object do
          j.field("created") { Server.expense_out(j, e, names, true) }
          j.field "note", "Created as entry #{id} with #{payer.name} as author. Changing or deleting it is only possible in the app."
        end
      end
    end
  end
end
