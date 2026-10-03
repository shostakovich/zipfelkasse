require "uri"

module Zipfelkasse::Web
  # Expenses per "Weitere anzeigen" step on the home page.
  HOME_PAGE_SIZE = 100

  # Offered in the form; other ISO codes via "Andere …".
  COMMON_CURRENCIES = %w(EUR USD GBP CHF DKK SEK NOK PLN CZK HUF TRY JPY CAD AUD)

  record HomeFilter, text : String = "", category_id : Int64 = 0_i64, participant_id : Int64 = 0_i64 do
    def active? : Bool
      !text.empty? || category_id != 0 || participant_id != 0
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
  record SplitRow, id : Int64, name : String, archived : Bool, checked : Bool, value : String = "", cents : Int64 = 0_i64

  # The form values as text, so that after an error they are shown again
  # exactly as entered.
  class ExpenseForm
    property id = 0_i64 # 0 = new expense
    property title = ""
    property date = ""
    property category = 0_i64
    property currency = "" # one of COMMON_CURRENCIES, "" = other
    property currency_other = ""
    property amount = "" # in the selected currency
    property rate = ""   # foreign currency per 1 EUR
    property rate_source = ""
    property paid_by = 0_i64
    property notes = ""
    property? reimbursement = false
    property split_mode : Domain::SplitMode = Domain::SPLIT_EQUAL
    property rows = [] of SplitRow
    property eur_cents = 0_i64 # converted amount for display, 0 = unknown

    def currency_code : String
      c = (currency.empty? ? currency_other : currency).strip.upcase
      c.empty? ? "EUR" : c
    end

    def checked_rows : Array(SplitRow)
      rows.select(&.checked)
    end
  end

  def self.form_from_expense(e : Store::Expense, people : Array(Store::Participant)) : ExpenseForm
    f = ExpenseForm.new
    f.id = e.id
    f.title = e.title
    f.date = Store.format_date(e.date)
    f.category = e.category_id
    f.paid_by = e.paid_by
    f.notes = e.notes
    f.reimbursement = e.reimbursement?
    f.split_mode = e.split_mode
    f.eur_cents = e.amount_cents
    cur = e.original_currency
    if COMMON_CURRENCIES.includes?(cur)
      f.currency = cur
    else
      f.currency_other = cur
    end
    if e.foreign?
      f.amount = Domain.format_minor_input(e.original_amount_minor, cur)
      f.rate = Domain.format_rate(e.fx_rate)
      f.rate_source = e.fx_source
    else
      f.amount = Domain.format_cents_input(e.amount_cents)
    end
    shares = e.shares.index_by(&.participant_id)
    people.each do |p|
      sh = shares[p.id]?
      next if p.archived? && sh.nil? && p.id != e.paid_by
      value = ""
      if sh
        value = case e.split_mode
                when Domain::SPLIT_SHARES  then sh.weight.to_s
                when Domain::SPLIT_PERCENT then Domain.format_basis_points(sh.weight).rchop(" %")
                when Domain::SPLIT_AMOUNT  then Domain.format_minor_input(sh.weight, cur) # original currency
                else                            ""
                end
      end
      f.rows << SplitRow.new(p.id, p.name, p.archived?, !sh.nil?, value, sh.try(&.amount_cents) || 0_i64)
    end
    f
  end

  # The empty form (all active people involved, I paid) or a prefilled
  # reimbursement (?rueckzahlung=1&von=ID&an=ID&betrag=cents).
  def self.new_expense_form(q : URI::Params, today : Time, me_id : Int64, people : Array(Store::Participant)) : ExpenseForm
    f = ExpenseForm.new
    f.date = Store.format_date(today)
    f.currency = "EUR"
    f.paid_by = me_id
    reimb = !q.fetch("rueckzahlung", "").empty?
    to = form_id(q.fetch("an", ""))
    if reimb
      f.reimbursement = true
      f.title = "Rückzahlung"
      from = form_id(q.fetch("von", ""))
      f.paid_by = from if from != 0
      if (c = q.fetch("betrag", "").to_i64?(whitespace: false)) && c > 0
        f.amount = Domain.format_cents_input(c)
      end
    end
    people.each do |p|
      next if p.archived? && p.id != f.paid_by && p.id != to
      checked = reimb ? p.id == to : !p.archived?
      f.rows << SplitRow.new(p.id, p.name, p.archived?, checked)
    end
    f
  end

  # Reads the posted form without validating it. people are all people;
  # archived ones are shown only if checked, in the existing expense or the
  # payer.
  def self.read_expense_form(r : Request, id : Int64, people : Array(Store::Participant), existing : Store::Expense?) : ExpenseForm
    f = ExpenseForm.new
    f.id = id
    f.title = r.post_form_value("titel")
    f.date = r.post_form_value("datum").strip
    f.category = form_id(r.post_form_value("kategorie"))
    f.currency = r.post_form_value("waehrung").strip.upcase
    f.currency_other = r.post_form_value("waehrung_andere").strip.upcase
    f.amount = r.post_form_value("betrag").strip
    f.rate = r.post_form_value("kurs").strip
    f.rate_source = r.post_form_value("kurs_quelle")
    f.paid_by = form_id(r.post_form_value("bezahlt_von"))
    f.notes = r.post_form_value("notiz")
    f.reimbursement = !r.post_form_value("rueckzahlung").empty?
    mode = Domain::SplitMode.new(r.post_form_value("aufteilung"))
    f.split_mode = mode.valid? ? mode : Domain::SPLIT_EQUAL
    checked = r.post_form_values("teil").map { |v| form_id(v) }.to_set
    in_existing = Set(Int64).new
    if existing
      in_existing << existing.paid_by
      existing.shares.each { |sh| in_existing << sh.participant_id }
    end
    people.each do |p|
      next if p.archived? && !checked.includes?(p.id) && !in_existing.includes?(p.id) && p.id != f.paid_by
      f.rows << SplitRow.new(p.id, p.name, p.archived?, checked.includes?(p.id), r.post_form_value("wert_#{p.id}").strip)
    end
    f
  end

  def self.reimbursement_parts(rows : Array(SplitRow)) : Array(Domain::Part)
    if rows.size != 1
      raise Domain::ValidationError.new("Eine Rückzahlung geht an genau eine Person – bitte genau einen Empfänger ankreuzen.")
    end
    [Domain::Part.new(rows[0].id)]
  end

  # Weights of the checked people for mode; amounts are in currency cur.
  # Error messages name the person.
  def self.split_parts(mode : Domain::SplitMode, cur : String, rows : Array(SplitRow)) : Array(Domain::Part)
    raise Domain::ValidationError.new("Bitte mindestens eine Person ankreuzen, für die bezahlt wurde.") if rows.empty?
    rows.map do |row|
      w = begin
        split_weight(mode, cur, row)
      rescue ex : Domain::ValidationError
        raise ex if ex.msg.starts_with?(row.name)
        raise Domain::ValidationError.new("#{row.name}: #{ex.msg}")
      end
      raise Domain::ValidationError.new("#{row.name}: Negative Werte sind nicht erlaubt.") if w < 0
      Domain::Part.new(row.id, w)
    end
  end

  # An empty value is 1 share, otherwise 0.
  def self.split_weight(mode : Domain::SplitMode, cur : String, row : SplitRow) : Int64
    v = row.value
    v = mode == Domain::SPLIT_SHARES ? "1" : "0" if v.empty?
    Domain.parse_weight(mode, cur, v)
  end

  class Handlers
    def register_expenses : Nil
      Web.route(@d, "GET", "/") { |r| home(r) }
      Web.route(@d, "GET", "/ausgaben/neu") { |r| expense_new(r) }
      Web.route(@d, "POST", "/ausgaben/neu") { |r| save_expense(r, nil) }
      Web.route(@d, "GET", "/ausgaben/:id") { |r| expense_show(r) }
      Web.route(@d, "POST", "/ausgaben/:id") { |r| expense_update(r) }
      Web.route(@d, "POST", "/ausgaben/:id/loeschen") { |r| expense_delete(r) }
    end

    def home(r : Request) : Nil
      me = r.me
      filter = HomeFilter.new(r.query("q").strip, Web.form_id(r.query("kategorie")), Web.form_id(r.query("person")))
      limit = HOME_PAGE_SIZE
      if (n = r.query("anzahl").to_i64?(whitespace: false)) && n > limit
        limit = Math.min(n, 100_000).to_i
      end
      expenses = @d.store.list_expenses(Store::ExpenseFilter.new(text: filter.text, category_id: filter.category_id,
        participant_id: filter.participant_id, limit: limit + 1))
      balance = @d.store.balances[me.id]? || 0_i64
      people = @d.store.list_participants(true)
      # Filter options: active entries plus the selected one (even if archived).
      categories = @d.store.list_categories(true).select { |c| !c.archived? || c.id == filter.category_id }
      participants = people.select { |p| !p.archived? || p.id == filter.participant_id }
      more = ""
      if expenses.size > limit
        expenses = expenses[0, limit]
        params = URI::Params.build do |q|
          q.add "anzahl", (limit + HOME_PAGE_SIZE).to_s
          q.add "kategorie", filter.category_id.to_s if filter.category_id != 0
          q.add "person", filter.participant_id.to_s if filter.participant_id != 0
          q.add "q", filter.text unless filter.text.empty?
        end
        more = "/?" + params
      end
      names = people.to_h { |p| {p.id, p.name} }
      active = people.reject(&.archived?).map(&.id).to_set
      groups = Web.group_expenses(expenses, @d.today, me.id, names, active)
      r.page(200, Page.new(title: "Ausgaben", nav: NAV_EXPENSES)) do |__io__|
        Web.template __io__, "web/home.ecr"
      end
    end

    def expense_new(r : Request) : Nil
      f = Web.new_expense_form(r.query_params, @d.today, r.me.id, @d.store.list_participants(true))
      render_expense(r, 200, f, nil, "")
    end

    def expense_show(r : Request) : Nil
      e = load_expense(r)
      render_expense(r, 200, Web.form_from_expense(e, @d.store.list_participants(true)), e, "")
    end

    def expense_update(r : Request) : Nil
      e = load_expense(r)
      raise HTTPError.new(409, "Diese Ausgabe wurde gelöscht und kann nicht mehr bearbeitet werden.") if e.deleted?
      save_expense(r, e)
    end

    def expense_delete(r : Request) : Nil
      e = load_expense(r)
      begin
        @d.store.delete_expense(r.me.id, e.id)
      rescue Store::NotFound
        raise HTTPError.not_found("Ausgabe nicht gefunden oder schon gelöscht.")
      end
      r.set_flash("„#{e.title}“ gelöscht.")
      r.redirect("/")
    end

    # Deleted expenses too.
    private def load_expense(r : Request) : Store::Expense
      id = r.path_id
      raise HTTPError.not_found("Ausgabe nicht gefunden.") if id == 0
      @d.store.get_expense(id)
    rescue Store::NotFound
      raise HTTPError.not_found("Ausgabe nicht gefunden.")
    end

    # Creates the expense (existing nil) or updates it.
    private def save_expense(r : Request, existing : Store::Expense?) : Nil
      raise HTTPError.new(400, "Ungültige Anfrage.") unless form_encoding_ok?(r)
      people = @d.store.list_participants(true)
      f = Web.read_expense_form(r, existing.try(&.id) || 0_i64, people, existing)
      begin
        input = to_input(f, existing)
        if existing
          @d.store.update_expense(r.me.id, existing.id, input)
        else
          @d.store.create_expense(r.me.id, input)
        end
      rescue ex : Domain::ValidationError
        return render_expense(r, 422, f, existing, ex.msg)
      rescue Store::NotFound
        raise HTTPError.not_found("Ausgabe nicht gefunden.")
      end
      kind = input.reimbursement? ? "Rückzahlung" : "Ausgabe"
      r.set_flash("#{kind} „#{Store.normalize_name(input.title)}“ #{existing ? "gespeichert" : "angelegt"}.")
      r.redirect("/")
    end

    # Broken percent escapes and ";" separators make the expense form a bad
    # request (400), although the parser silently accepts them.
    private def form_encoding_ok?(r : Request) : Bool
      ok = ->(s : String) { !s.includes?(';') && Web.valid_escapes?(s) }
      return false unless ok.call(r.request.query || "")
      type = (r.request.headers["Content-Type"]? || "").partition(';')[0].strip.downcase
      type != "application/x-www-form-urlencoded" || ok.call(r.ctx.params.raw_body)
    end

    # Validates the form and builds the store input. A missing or ECB rate
    # for a foreign currency is looked up and copied into the form.
    private def to_input(f : ExpenseForm, existing : Store::Expense?) : Store::ExpenseInput
      input = Store::ExpenseInput.new(title: f.title, category_id: f.category, paid_by: f.paid_by, notes: f.notes,
        reimbursement: f.reimbursement?, split_mode: f.split_mode)
      raise Domain::ValidationError.new("Bitte einen Titel angeben.") if f.title.strip.empty?
      date = Domain.parse_date(f.date)
      input.date = date
      cur = f.currency_code
      unless Domain.valid_currency_code?(cur)
        raise Domain::ValidationError.new("Ungültige Währung „#{cur}“ – bitte einen dreistelligen ISO-Code wie USD angeben.")
      end
      if cur == "EUR"
        input.amount_cents = Domain.parse_cents(f.amount)
        raise Domain::ValidationError.new("Der Betrag muss größer als 0 sein.") if input.amount_cents <= 0
      else
        # The store converts foreign amounts itself; eur_cents is for the form.
        input.original_amount_minor = Domain.parse_minor(f.amount, Domain.currency_decimals(cur))
        raise Domain::ValidationError.new("Der Betrag muss größer als 0 sein.") if input.original_amount_minor <= 0
        input.original_currency = cur
        input.fx_rate, input.fx_source = form_rate(f, cur, date, existing)
        f.eur_cents = Domain.to_eur_cents(input.original_amount_minor, cur, input.fx_rate)
      end
      rows = f.checked_rows
      if f.reimbursement?
        input.split_mode = Domain::SPLIT_EQUAL
        input.parts = Web.reimbursement_parts(rows)
      else
        input.parts = Web.split_parts(input.split_mode, cur, rows)
      end
      input
    end

    # Rate and source for a foreign currency expense:
    # - no rate in the form: the ECB rate of cur on date (copied into the form);
    # - a rate marked as ECB (kurs_quelle, set by expense-form.js) is checked
    #   against the ECB rate of cur on date, since without JS a rate fetched
    #   for another currency or date stays in the field. A differing rate is
    #   replaced by the looked-up one. Saving with unchanged currency, date
    #   and rate keeps the saved rate, so a later published rate does not
    #   change it;
    # - any other rate counts as entered by hand.
    private def form_rate(f : ExpenseForm, cur : String, date : Time, existing : Store::Expense?) : {Float64, String}
      unless f.rate.empty?
        rate = Domain.parse_rate(f.rate)
        return {rate, Domain::FX_SOURCE_MANUAL} if f.rate_source != Domain::FX_SOURCE_ECB
        if existing && existing.fx_source == Domain::FX_SOURCE_ECB && existing.original_currency == cur &&
           existing.date == date && existing.fx_rate == rate
          return {rate, Domain::FX_SOURCE_ECB}
        end
      end
      looked = begin
        lookup_rate(cur, date)
      rescue ex : Domain::ValidationError
        f.rate = ""
        f.rate_source = ""
        raise ex
      end
      f.rate = Domain.format_rate(looked.rate)
      f.rate_source = looked.source
      {looked.rate, looked.source}
    end

    private def lookup_rate(cur : String, date : Time) : Domain::FXRate
      unavailable = Domain::ValidationError.new(
        "Für #{cur} ist am #{Domain.format_date(date)} kein Wechselkurs verfügbar. Kurs bitte von Hand eintragen.")
      fx = @d.fx || raise unavailable
      rate = begin
        fx.rate(cur, date)
      rescue ex
        Log.info(exception: ex, &.emit("rate not available", currency: cur, date: Store.format_date(date)))
        raise unavailable
      end
      raise unavailable unless rate.rate > 0
      rate.source.empty? ? rate.copy_with(source: Domain::FX_SOURCE_ECB) : rate
    end

    private def render_expense(r : Request, status : Int32, f : ExpenseForm, e : Store::Expense?, error : String) : Nil
      deleted = e.try(&.deleted?) || false
      cur = f.currency_code
      people = @d.store.list_participants(true)
      categories = @d.store.list_categories(true).select { |c| !c.archived? || c.id == f.category }
      payers = people.select { |p| !p.archived? || p.id == f.paid_by }
      # The form preview distributes leftover cents by expense ID like the store.
      rotation = f.id != 0 ? f.id : @d.store.next_expense_id
      suggest = Web.suggest_categories(@d.store.category_history).to_json
      history = [] of ActivityItem
      if e
        history = Web.activity_items(@d.store.list_activity(Store::ActivityFilter.new(expense_id: e.id, limit: 50)))
      end
      page = Page.new(title: e ? e.title : "Neue Ausgabe", nav: NAV_EXPENSES, error: error, scripts: ["expense-form.js"])
      r.page(status, page) do |__io__|
        Web.template __io__, "web/expense.ecr"
      end
    end
  end
end
