require "uri"

module Zipfelkasse::Web
  # Expenses per "Weitere anzeigen" step on the home page.
  HOME_PAGE_SIZE =   100
  HOME_MAX_ROWS  = 5_000

  # Offered in the form; other ISO codes via "Andere …".
  COMMON_CURRENCIES = %w(EUR USD GBP CHF DKK SEK NOK PLN CZK HUF TRY JPY CAD AUD)

  record HomeFilter, text : String = "", category_id : Int64? = nil, participant_id : Int64? = nil do
    def active? : Bool
      !text.empty? || !category_id.nil? || !participant_id.nil?
    end
  end

  # A row of the expense list. everyone: all active people are involved
  # (from 4 people on); involved: the current person pays or has a share.
  record ExpenseRow, expense : Store::Expense, for_names : Array(String), everyone : Bool, involved : Bool,
    my_balance : Int64 do
    delegate id, title, date, reimbursement?, category_name, paid_by_name, recurring_id, amount_cents,
      original_amount_minor, original_currency, foreign?, to: @expense
  end

  # Splits the expenses (sorted by date, descending) into labelled periods.
  # active holds the IDs of the active people.
  def self.group_expenses(es : Array(Store::Expense), today : Time, me_id : Int64, names : Hash(Int64, String),
                          active : Set(Int64)) : Array({String, Array(ExpenseRow)})
    rows = es.map do |e|
      # Shares are unique per person: same count and all active means
      # exactly the active people.
      everyone = active.size >= 4 && e.shares.size == active.size && e.shares.all? { |sh| active.includes?(sh.participant_id) }
      involved = e.paid_by == me_id || e.shares.any? { |sh| sh.participant_id == me_id }
      my_balance = (e.paid_by == me_id ? e.amount_cents : 0_i64) - e.share_of(me_id)
      ExpenseRow.new(e, e.shares.map { |sh| names[sh.participant_id]? || "" }, everyone, involved, my_balance)
    end
    rows.chunks { |row| expense_period(row.date, today) }
  end

  # A person in the split of the expense form. value holds shares, percent
  # or an amount depending on the mode; cents is the computed share (saved
  # expenses only).
  record SplitRow, id : Int64, name : String, archived : Bool, checked : Bool, value : String = "", cents : Int64? = nil

  # Raised with the form as it is to be shown again.
  class InvalidForm < Domain::ValidationError
    getter form : ExpenseForm

    def initialize(message : String, @form)
      super(message)
    end
  end

  # The values as text, so that after an error they are shown again exactly
  # as entered.
  record ExpenseForm,
    id : Int64? = nil,
    title : String = "",
    date : String = "",
    category_id : Int64? = nil,
    currency : String? = "EUR", # one of COMMON_CURRENCIES, nil = other
    currency_other : String = "",
    amount : String = "", # in the selected currency
    rate : String = "",   # foreign currency per 1 EUR
    rate_source : Domain::FXSource? = nil,
    paid_by : Int64? = nil,
    notes : String = "",
    reimbursement : Bool = false,
    split_mode : Domain::SplitMode = Domain::SplitMode::Equal,
    rows : Array(SplitRow) = [] of SplitRow,
    eur_cents : Int64? = nil do # converted amount for display
    def self.from_expense(e : Store::Expense, people : Array(Store::Participant)) : ExpenseForm
      currency = e.original_currency
      common = COMMON_CURRENCIES.includes?(currency)
      shares = e.shares.index_by(&.participant_id)
      rows = people.compact_map do |p|
        share = shares[p.id]?
        next if p.archived? && share.nil? && p.id != e.paid_by
        value = share.try { |sh| share_value(e, sh) } || ""
        cents = share.try(&.amount_cents)
        SplitRow.new(p.id, p.name, p.archived?, !share.nil?, value, cents == 0 ? nil : cents)
      end
      new(id: e.id, title: e.title, date: Store.format_date(e.date), category_id: e.category_id,
        currency: common ? currency : nil, currency_other: common ? "" : currency,
        amount: e.foreign? ? Domain.format_minor_input(e.original_amount_minor, currency) : Domain.format_cents_input(e.amount_cents),
        rate: e.foreign? ? Domain.format_rate(e.fx_rate) : "", rate_source: e.foreign? ? e.fx_source : nil,
        paid_by: e.paid_by, notes: e.notes, reimbursement: e.reimbursement?, split_mode: e.split_mode, rows: rows,
        eur_cents: e.amount_cents)
    end

    private def self.share_value(e : Store::Expense, share : Domain::Share) : String
      case e.split_mode
      in .equal?   then ""
      in .shares?  then share.weight.to_s
      in .percent? then Domain.format_basis_points(share.weight).rchop(" %")
      in .amount?  then Domain.format_minor_input(share.weight, e.original_currency)
      end
    end

    # The empty form (all active people involved, I paid) or a prefilled
    # reimbursement (?rueckzahlung=1&von=ID&an=ID&betrag=cents).
    def self.blank(query : URI::Params, today : Time, me_id : Int64, people : Array(Store::Participant)) : ExpenseForm
      reimbursement = !query["rueckzahlung"]?.presence.nil?
      to = Web.positive_id?(query["an"]?, trim: true)
      paid_by = (reimbursement ? Web.positive_id?(query["von"]?, trim: true) : nil) || me_id
      cents = query["betrag"]?.try(&.to_i64?(whitespace: false))
      rows = people.compact_map do |p|
        next if p.archived? && p.id != paid_by && p.id != to
        SplitRow.new(p.id, p.name, p.archived?, reimbursement ? p.id == to : !p.archived?)
      end
      new(date: Store.format_date(today), paid_by: paid_by, reimbursement: reimbursement, rows: rows,
        title: reimbursement ? Domain::REIMBURSEMENT_TITLE : "",
        amount: reimbursement && cents && cents > 0 ? Domain.format_cents_input(cents) : "")
    end

    # Reads a posted form without validating it. people are all people;
    # archived ones are shown only if checked, in the existing expense or the
    # payer.
    def self.from_post(body : URI::Params, existing : Store::Expense?, people : Array(Store::Participant)) : ExpenseForm
      paid_by = Web.positive_id?(body["bezahlt_von"]?, trim: true)
      checked = body.fetch_all("teil").compact_map { |v| Web.positive_id?(v, trim: true) }.to_set
      in_existing = Set(Int64).new
      existing.try do |e|
        in_existing << e.paid_by
        e.shares.each { |sh| in_existing << sh.participant_id }
      end
      rows = people.compact_map do |p|
        next if p.archived? && !checked.includes?(p.id) && !in_existing.includes?(p.id) && p.id != paid_by
        SplitRow.new(p.id, p.name, p.archived?, checked.includes?(p.id), (body["wert_#{p.id}"]? || "").strip)
      end
      new(id: existing.try(&.id), title: body["titel"]? || "", date: (body["datum"]? || "").strip,
        category_id: Web.positive_id?(body["kategorie"]?, trim: true),
        currency: (body["waehrung"]? || "").strip.upcase.presence, currency_other: (body["waehrung_andere"]? || "").strip.upcase,
        amount: (body["betrag"]? || "").strip, rate: (body["kurs"]? || "").strip,
        rate_source: Domain::FXSource.from_key?(body["kurs_quelle"]? || ""), paid_by: paid_by,
        notes: body["notiz"]? || "", reimbursement: !body["rueckzahlung"]?.presence.nil?,
        split_mode: Domain::SplitMode.from_key?(body["aufteilung"]? || "") || Domain::SplitMode::Equal, rows: rows)
    end

    def reimbursement? : Bool
      reimbursement
    end

    def currency_code : String
      code = (currency || currency_other).strip.upcase
      code.empty? ? "EUR" : code
    end

    def checked_rows : Array(SplitRow)
      rows.select(&.checked)
    end

    # Weights of the checked people. Error messages name the person.
    def parts : Array(Domain::Part)
      checked = checked_rows
      if reimbursement?
        raise Domain::ValidationError.new("Eine Rückzahlung geht an genau eine Person – bitte genau einen Empfänger ankreuzen.") if checked.size != 1
        return [Domain::Part.new(checked[0].id)]
      end
      raise Domain::ValidationError.new("Bitte mindestens eine Person ankreuzen, für die bezahlt wurde.") if checked.empty?
      checked.map do |row|
        weight = begin
          weight_of(row)
        rescue ex : Domain::ValidationError
          raise ex if ex.msg.starts_with?(row.name)
          raise Domain::ValidationError.new("#{row.name}: #{ex.msg}")
        end
        raise Domain::ValidationError.new("#{row.name}: Negative Werte sind nicht erlaubt.") if weight < 0
        Domain::Part.new(row.id, weight)
      end
    end

    # An empty value is 1 share, otherwise 0.
    private def weight_of(row : SplitRow) : Int64
      value = row.value
      value = split_mode.shares? ? "1" : "0" if value.empty?
      Domain.parse_weight(split_mode, currency_code, value)
    end
  end

  module Views
    record Home, filter : HomeFilter, balance : Int64, categories : Array(Store::Category),
      participants : Array(Store::Participant), groups : Array({String, Array(ExpenseRow)}), more : String? do
      Web.view "web/home.ecr"
    end

    record Expense, form : ExpenseForm, expense : Store::Expense?, categories : Array(Store::Category),
      payers : Array(Store::Participant), suggest : String, rotation : Int64, history : Array(ActivityItem) do
      Web.view "web/expense.ecr"

      def deleted? : Bool
        expense.try(&.deleted?) || false
      end

      def currency : String
        form.currency_code
      end
    end
  end

  class ExpensesController < Controller
    def register : Nil
      get("/") { |env| home(env) }
      get("/ausgaben/neu") { |env| new_form(env) }
      post("/ausgaben/neu") { |env| save(env, nil) }
      get("/ausgaben/:id") { |env| show(env) }
      post("/ausgaben/:id") { |env| update(env) }
      post("/ausgaben/:id/loeschen") { |env| delete(env) }
    end

    private def home(env : HTTP::Server::Context) : String
      me = env.me
      filter = HomeFilter.new(env.query("q").strip, Web.positive_id?(env.query("kategorie"), trim: true),
        Web.positive_id?(env.query("person"), trim: true))
      limit = (env.query("anzahl").to_i64?(whitespace: false) || 0).clamp(HOME_PAGE_SIZE, HOME_MAX_ROWS).to_i
      expenses = @d.store.list_expenses(Store::ExpenseFilter.new(text: filter.text, category_id: filter.category_id,
        participant_id: filter.participant_id, limit: limit + 1))
      people = @d.store.list_participants(true)
      more = nil
      if expenses.size > limit
        expenses = expenses[0, limit]
        if limit < HOME_MAX_ROWS
          query = URI::Params.build do |q|
            q.add "anzahl", (limit + HOME_PAGE_SIZE).to_s
            q.add "kategorie", filter.category_id.to_s if filter.category_id
            q.add "person", filter.participant_id.to_s if filter.participant_id
            q.add "q", filter.text unless filter.text.empty?
          end
          more = "/?#{query}"
        end
      end
      names = people.to_h { |p| {p.id, p.name} }
      active = people.reject(&.archived?).map(&.id).to_set
      groups = Web.group_expenses(expenses, @d.today, me.id, names, active)
      view = Views::Home.new(filter, @d.store.balances[me.id]? || 0_i64,
        @d.store.list_categories(true).select { |c| !c.archived? || c.id == filter.category_id },
        people.select { |p| !p.archived? || p.id == filter.participant_id }, groups, more)
      page(env, view, "Ausgaben", Nav::Expenses)
    end

    private def new_form(env : HTTP::Server::Context) : String
      form = ExpenseForm.blank(env.params.query, @d.today, env.me.id, @d.store.list_participants(true))
      show_form(env, 200, form, nil)
    end

    private def show(env : HTTP::Server::Context) : String
      expense = find_expense(env)
      show_form(env, 200, ExpenseForm.from_expense(expense, @d.store.list_participants(true)), expense)
    end

    private def update(env : HTTP::Server::Context) : String
      expense = find_expense(env)
      raise HTTPError.new(env, 409, "Diese Ausgabe wurde gelöscht und kann nicht mehr bearbeitet werden.") if expense.deleted?
      save(env, expense)
    end

    private def delete(env : HTTP::Server::Context) : String
      expense = find_expense(env)
      or_404(env, "Ausgabe nicht gefunden oder schon gelöscht.") { @d.store.delete_expense(env.me.id, expense.id) }
      redirect(env, "/", "„#{expense.title}“ gelöscht.")
    end

    # Deleted expenses too.
    private def find_expense(env : HTTP::Server::Context) : Store::Expense
      id = path_id(env)
      or_404(env, "Ausgabe nicht gefunden.", id && @d.store.get_expense?(id))
    end

    private def save(env : HTTP::Server::Context, existing : Store::Expense?) : String
      form = ExpenseForm.from_post(env.params.body, existing, @d.store.list_participants(true))
      begin
        input, form = build_input(form, existing)
        if existing
          @d.store.update_expense(env.me.id, existing.id, input)
        else
          @d.store.create_expense(env.me.id, input)
        end
      rescue ex : InvalidForm
        return show_form(env, 422, ex.form, existing, ex.msg)
      rescue ex : Domain::ValidationError
        return show_form(env, 422, form, existing, ex.msg)
      rescue Store::NotFound
        raise HTTPError.new(env, 404, "Ausgabe nicht gefunden.")
      end
      kind = input.reimbursement? ? Domain::REIMBURSEMENT_TITLE : "Ausgabe"
      redirect(env, "/", "#{kind} „#{Store.normalize_name(input.title)}“ #{existing ? "gespeichert" : "angelegt"}.")
    end

    # Validates the form and builds the store input. A missing or ECB rate
    # for a foreign currency is looked up; the returned form shows it.
    private def build_input(form : ExpenseForm, existing : Store::Expense?) : {Store::ExpenseInput, ExpenseForm}
      raise Domain::ValidationError.new("Bitte einen Titel angeben.") if form.title.strip.empty?
      date = Domain.parse_date(form.date)
      currency = form.currency_code
      unless Domain.valid_currency_code?(currency)
        raise Domain::ValidationError.new("Ungültige Währung „#{currency}“ – bitte einen dreistelligen ISO-Code wie USD angeben.")
      end
      amount_cents = 0_i64
      original_minor = 0_i64
      rate = source = nil
      if Domain.eur?(currency)
        amount_cents = Domain.parse_cents(form.amount)
        raise Domain::ValidationError.new("Der Betrag muss größer als 0 sein.") if amount_cents <= 0
      else
        original_minor = Domain.parse_minor(form.amount, Domain.currency_decimals(currency))
        raise Domain::ValidationError.new("Der Betrag muss größer als 0 sein.") if original_minor <= 0
        rate, source = resolve_rate(form, currency, date, existing)
        form = form.copy_with(rate: Domain.format_rate(rate), rate_source: source)
        begin
          form = form.copy_with(eur_cents: Domain.to_eur_cents(original_minor, currency, rate))
        rescue ex : Domain::ValidationError
          raise InvalidForm.new(ex.msg, form)
        end
      end
      parts = begin
        form.parts
      rescue ex : Domain::ValidationError
        raise InvalidForm.new(ex.msg, form)
      end
      input = Store::ExpenseInput.new(title: form.title, date: date, category_id: form.category_id, paid_by: form.paid_by,
        notes: form.notes, reimbursement: form.reimbursement?,
        split_mode: form.reimbursement? ? Domain::SplitMode::Equal : form.split_mode, amount_cents: amount_cents,
        parts: parts, original_amount_minor: original_minor, original_currency: currency, fx_rate: rate, fx_source: source)
      {input, form}
    end

    # Rate and source for a foreign currency expense:
    # - no rate in the form: the ECB rate of the currency on date;
    # - a rate marked as ECB (kurs_quelle, set by expense-form.js) is checked
    #   against the ECB rate of that currency and date, since without JS a rate
    #   fetched for another currency or date stays in the field. A differing
    #   rate is replaced by the looked-up one. Saving with unchanged currency,
    #   date and rate keeps the saved rate, so a later published rate does not
    #   change it;
    # - any other rate counts as entered by hand.
    private def resolve_rate(form : ExpenseForm, currency : String, date : Time,
                             existing : Store::Expense?) : {Float64, Domain::FXSource}
      unless form.rate.empty?
        rate = Domain.parse_rate(form.rate)
        return {rate, Domain::FXSource::Manual} unless form.rate_source.try(&.ecb?)
        if existing && existing.fx_source.try(&.ecb?) && existing.original_currency == currency &&
           existing.date == date && existing.fx_rate == rate
          return {rate, Domain::FXSource::Ecb}
        end
      end
      looked = begin
        lookup_rate(currency, date)
      rescue ex : Domain::ValidationError
        raise InvalidForm.new(ex.msg, form.copy_with(rate: "", rate_source: nil))
      end
      {looked.rate, looked.source}
    end

    private def lookup_rate(currency : String, date : Time) : Domain::FXRate
      unavailable = Domain::ValidationError.new(
        "Für #{currency} ist am #{Domain.format_date(date)} kein Wechselkurs verfügbar. Kurs bitte von Hand eintragen.")
      rate = begin
        @d.fx.rate(currency, date)
      rescue ex
        Log.info(exception: ex, &.emit("rate not available", currency: currency, date: Store.format_date(date)))
        raise unavailable
      end
      raise unavailable unless rate.rate > 0
      rate
    end

    private def show_form(env : HTTP::Server::Context, status : Int32, form : ExpenseForm, expense : Store::Expense?,
                          error : String? = nil) : String
      payers = @d.store.list_participants(true).select { |p| !p.archived? || p.id == form.paid_by }
      categories = @d.store.list_categories(true).select { |c| !c.archived? || c.id == form.category_id }
      history = expense ? Web.activity_items(@d.store.list_activity(Store::ActivityFilter.new(expense_id: expense.id, limit: 50))) : [] of ActivityItem
      # The form preview distributes leftover cents by expense ID like the store.
      rotation = form.id || @d.store.next_expense_id
      suggest = Web.suggest_categories(@d.store.category_history).to_json
      view = Views::Expense.new(form, expense, categories, payers, suggest, rotation, history)
      page(env, view, expense ? expense.title : "Neue Ausgabe", Nav::Expenses, status, error, ["expense-form.js"])
    end
  end
end
