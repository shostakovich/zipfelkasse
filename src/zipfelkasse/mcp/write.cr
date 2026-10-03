module Zipfelkasse::MCP
  class DecimalError < Exception
  end

  STRICT_DECIMAL = /\A[0-9]+(\.[0-9]*)?\z/

  # Unlike the form, no thousands separators: "1.234" is never 1234.
  def self.parse_decimal(text : String, decimals : Int32) : Int64
    text = text.strip
    unless STRICT_DECIMAL.matches?(text)
      raise DecimalError.new("use digits with a dot as decimal separator and no thousands separator, e.g. 1234.50")
    end
    whole, _, fraction = text.partition('.')
    if fraction.rstrip('0').size > decimals
      raise DecimalError.new(decimals == 0 ? "must be a whole number" : "at most #{decimals} decimal places")
    end
    raise DecimalError.new("too large") if whole.size > 15
    Domain.parse_minor(text.rchop('.').tr(".", ","), decimals)
  end

  def self.split_parts(directory : Directory, mode : Domain::SplitMode, currency : String, participants : Array(String),
                       weights : Hash(String, String)) : Array(Domain::Part)
    parts = [] of Domain::Part
    seen = Set(Int64).new
    add = ->(name : String, weight : Int64) do
      person = directory.active("the split", name)
      raise invalid("#{person.name} appears twice in the split.") unless seen.add?(person.id)
      parts << Domain::Part.new(person.id, weight)
    end
    if mode.equal?
      unless weights.empty?
        raise invalid("weights are only for split=shares, percent or amount; use participants for an equal split.")
      end
      return directory.people.reject(&.archived?).map { |person| Domain::Part.new(person.id) } if participants.empty?
      participants.each { |name| add.call(name, 0_i64) }
      return parts
    end
    key = mode.to_s.underscore
    raise invalid("With split=#{key}, weights name the participants; leave participants out.") unless participants.empty?
    raise invalid("split=#{key} needs weights (person name → value).") if weights.empty?
    weights.keys.sort!.each do |name|
      weight = begin
        parse_decimal(weights[name], Domain.weight_decimals(mode, currency))
      rescue ex : DecimalError
        raise invalid("Invalid value #{weights[name].inspect} for #{name} in weights: #{ex.message}.")
      end
      add.call(name, weight)
    end
    parts
  end

  class Server
    private def register_write_tools : Nil
      amount = Schema.text_or_number(%(Amount in currency (default EUR) with a dot as decimal separator, e.g. "23.40".))
      currency = Schema.text("ISO currency code, e.g. USD. Default EUR.")
      rate = Schema.number("Only for a foreign currency: units of that currency per 1 EUR. Default: the ECB reference rate of the date.",
        exclusive_minimum: 0)
      duplicate = ->(same : String) do
        Schema.flag("Create it even if an entry with the same date, payer, amount and #{same} exists. Only set after asking the user.")
      end

      add(ExpenseArgs, "create_expense", "Create expense",
        "Creates an expense, as if the payer had entered it in the app. Ask the user before calling it if anything is unclear " \
        "(amount, payer, who takes part); then tell them what was created. Without participants and weights, the amount is " \
        "split equally among all active people. An entry with the same date, payer, amount and title is refused unless allow_duplicate is set. " \
        "Settlement payments between people are not expenses: use create_reimbursement for them.",
        {
          "title"        => Schema.text(%(What was bought, e.g. "Rewe" or "Pizza" (usually German, like the existing titles).)),
          "amount"       => amount,
          "currency"     => currency,
          "fx_rate"      => rate,
          "date"         => Schema.date("Date of the expense. Default today."),
          "paid_by"      => Schema.text("Name of the person who paid."),
          "category"     => Schema.text("Category name (case-insensitive). Empty = no category."),
          "split"        => Schema.choice(Domain::SplitMode, "equal (default): evenly among participants. shares, percent, amount: by the values in weights."),
          "participants" => Schema.list_of_text("Only for split=equal: names of the people the expense is for. Default: all active people."),
          "weights"      => Schema.map_of_text_or_number(
            %(For shares, percent and amount: person name → value, e.g. {"Anna": 2, "Ben": 1} (shares), {"Anna": 70, "Ben": 30} (percent, sum 100) ) +
            %(or {"Anna": "15.00", "Ben": "8.40"} (amounts in currency, sum = amount). These people are the participants.)),
          "notes"           => Schema.text("Optional note."),
          "allow_duplicate" => duplicate.call("title"),
        }, ["title", "amount", "paid_by"], WRITE) { |a| create_expense(a) }

      add(ReimbursementArgs, "create_reimbursement", "Create reimbursement",
        "Records a settlement payment: from paid amount to to (e.g. a bank transfer to settle up). It changes the balances, but is not an expense. " \
        "An entry with the same date, payer, amount and recipient is refused unless allow_duplicate is set.",
        {
          "from"            => Schema.text("Name of the person who paid the money."),
          "to"              => Schema.text("Name of the person who received it."),
          "amount"          => amount,
          "currency"        => currency,
          "fx_rate"         => rate,
          "date"            => Schema.date("Date of the payment. Default today."),
          "notes"           => Schema.text("Optional note."),
          "allow_duplicate" => duplicate.call("recipient"),
        }, ["from", "to", "amount"], WRITE) { |a| create_reimbursement(a) }
    end

    private def create_expense(a : ExpenseArgs) : CreatedOut
      title = MCP.given(a.title) || raise MCP.invalid("Parameter title is missing.")
      raise MCP.invalid("title must be at most #{Store::MAX_TITLE_LEN} characters.") if title.size > Store::MAX_TITLE_LEN
      mode = a.split || Domain::SplitMode::Equal
      date = date_or_today(a.date)
      input = Store::ExpenseInput.new(title: title, notes: notes(a.notes), split_mode: mode, date: date)
      input = set_money(input, a, date)
      directory = self.directory
      payer = directory.active("paid_by", a.paid_by)
      input.paid_by = payer.id
      MCP.given(a.category).try do |name|
        category = find_category(name)
        raise MCP.invalid("Category #{category.name} is archived.") if category.archived?
        input.category_id = category.id
      end
      input.parts = MCP.split_parts(directory, mode, input.original_currency, a.participants, a.weights)
      create(input, payer, directory, a.allow_duplicate)
    end

    private def create_reimbursement(a : ReimbursementArgs) : CreatedOut
      date = date_or_today(a.date)
      input = Store::ExpenseInput.new(title: Domain::REIMBURSEMENT_TITLE, notes: notes(a.notes), reimbursement: true, date: date)
      input = set_money(input, a, date)
      directory = self.directory
      from = directory.active("from", a.from)
      to = directory.active("to", a.to)
      raise MCP.invalid("from and to must be different people.") if from.id == to.id
      input.paid_by = from.id
      input.parts = [Domain::Part.new(to.id)]
      create(input, from, directory, a.allow_duplicate)
    end

    private def notes(value : String?) : String
      text = value.try(&.strip) || ""
      if text.gsub("\r\n", "\n").size > Store::MAX_NOTES_LEN
        raise MCP.invalid("notes must be at most #{Store::MAX_NOTES_LEN} characters.")
      end
      text
    end

    private def date_or_today(value : String?) : Time
      MCP.parse_date_arg("date", value) || today
    end

    private def set_money(input : Store::ExpenseInput, a : MoneyArgs, date : Time) : Store::ExpenseInput
      currency = (MCP.given(a.currency) || "EUR").upcase
      unless Domain.valid_currency_code?(currency)
        raise MCP.invalid("currency must be a three-letter ISO code such as USD, not #{a.currency.inspect}.")
      end
      amount = MCP.given(a.amount) || raise MCP.invalid("Parameter amount is missing.")
      minor = begin
        MCP.parse_decimal(amount, Domain.currency_decimals(currency))
      rescue ex : DecimalError
        raise MCP.invalid("Invalid amount #{a.amount.inspect} for #{currency}: #{ex.message}")
      end
      raise MCP.invalid("amount must be greater than 0.") if minor <= 0
      rate = a.fx_rate
      if currency == "EUR"
        raise MCP.invalid("fx_rate is only for foreign currencies.") if rate
        input.amount_cents = minor
        return input
      end
      input.original_amount_minor, input.original_currency = minor, currency
      if rate
        raise MCP.invalid("fx_rate must be greater than 0.") if rate <= 0
        input.fx_rate, input.fx_source = rate, Domain::FXSource::Manual
        return input
      end
      no_rate = MCP.invalid("There is no exchange rate for #{currency} on #{Store.format_date(date)}. Ask the user for the rate and pass it as fx_rate.")
      fx = @d.fx || raise no_rate
      found = begin
        fx.rate(currency, date)
      rescue ex
        Log.info(exception: ex, &.emit("mcp: rate not available", currency: currency, date: Store.format_date(date)))
        raise no_rate
      end
      raise no_rate unless found.rate > 0
      input.fx_rate, input.fx_source = found.rate, found.source
      input
    end

    private def create(input : Store::ExpenseInput, payer : Store::Participant, directory : Directory,
                       allow_duplicate : Bool) : CreatedOut
      cents = euro_cents(input)
      if !allow_duplicate && cents > 0 && (same = duplicate_of(input, cents))
        raise MCP.invalid("This looks like a duplicate of entry #{same.id} (#{Store.format_date(same.date)}, #{same.title}, " \
                          "#{MCP.eur(same.amount_cents)} EUR, paid by #{same.paid_by_name}). " \
                          "Ask the user; if it really is a second one, call again with allow_duplicate=true.")
      end
      id = begin
        @d.store.create_expense(payer.id, input, text: "Über MCP angelegt")
      rescue ex : Domain::ValidationError
        # The app's own rules (e.g. sum of the split) answer in German.
        raise MCP.invalid("The app refused the entry (message in German): #{ex.message}")
      end
      Log.info(&.emit("mcp: entry created", id: id, reimbursement: input.reimbursement?))
      CreatedOut.new(ExpenseOut.new(@d.store.get_expense(id), directory.names, true),
        "Created as entry #{id} with #{payer.name} as author. Changing or deleting it is only possible in the app.")
    end

    private def euro_cents(input : Store::ExpenseInput) : Int64
      return input.amount_cents if Domain.eur?(input.original_currency)
      Domain.to_eur_cents(input.original_amount_minor, input.original_currency, input.fx_rate.not_nil!)
    rescue Domain::ValidationError
      0_i64
    end

    private def duplicate_of(input : Store::ExpenseInput, cents : Int64) : Store::Expense?
      filter = Store::ExpenseFilter.new(from: input.date, to: input.date, paid_by: input.paid_by, min_cents: cents, max_cents: cents)
      @d.store.list_expenses(filter).find do |e|
        next false if e.reimbursement? != input.reimbursement?
        if input.reimbursement?
          e.share_of(input.parts[0].participant_id) != 0
        else
          e.title.downcase(:fold) == input.title.downcase(:fold)
        end
      end
    end
  end
end
