require "./expense_helper"

private alias Domain = Zipfelkasse::Domain
private alias Store = Zipfelkasse::Store

describe "expense pages" do
  it "renders the empty home page" do
    with_expense_group do |g|
      status, body = g.get("/")
      status.should eq 200
      body.should contain %(<a href="/" aria-current="page">)
      body.should contain "<title>Ausgaben · Zipfelkasse</title>"
      body.should contain "Noch keine Ausgaben."
      body.should contain "Alles ausgeglichen."
    end
  end

  describe "creating with the split modes" do
    # Expense 1: the extra cent goes to index 1 mod 3 (Ben).
    [
      {"equal", "equal", "10,00", {} of String => String, %w(anna ben cleo), {"anna" => 333, "ben" => 334, "cleo" => 333}},
      {"equal two", "equal", "10,00", {} of String => String, %w(ben cleo), {"ben" => 500, "cleo" => 500}},
      {"shares", "shares", "40,00", {"anna" => "2", "ben" => "1", "cleo" => ""}, %w(anna ben cleo),
       {"anna" => 2000, "ben" => 1000, "cleo" => 1000}},
      {"percent", "percent", "10,00", {"anna" => "50", "ben" => "25,5", "cleo" => "24,5"}, %w(anna ben cleo),
       {"anna" => 500, "ben" => 255, "cleo" => 245}},
      {"amounts", "amount", "10,00", {"anna" => "5", "ben" => "3,50", "cleo" => "1,50"}, %w(anna ben cleo),
       {"anna" => 500, "ben" => 350, "cleo" => 150}},
    ].each do |name, mode, amount, values, who, want|
      it name do
        with_expense_group do |g|
          ids = {"anna" => g.anna, "ben" => g.ben, "cleo" => g.cleo}
          v = g.form
          v["aufteilung"] = mode
          v["betrag"] = amount
          v.delete_all("teil")
          who.each { |n| v.add("teil", ids[n].to_s) }
          values.each { |n, val| v["wert_#{ids[n]}"] = val }
          e = g.create(v)
          e.split_mode.value.should eq mode
          shares_of(e).should eq want.to_h { |n, c| {ids[n], c.to_i64} }
          {e.title, e.category_id, e.paid_by, Store.format_date(e.date)}.should eq({"Einkauf", g.food, g.anna, "2026-09-30"})
        end
      end
    end
  end

  it "sets a flash and lists the new expense" do
    with_expense_group do |g|
      v = g.form
      v["datum"] = Store.format_date(g.srv.d.today)
      v["titel"] = "Wochenmarkt"
      res = g.srv.post_form("/ausgaben/neu", v, g.cookie)
      res.status_code.should eq 303
      flash = res.cookies[Zipfelkasse::Web::FLASH_COOKIE]? || fail "no flash cookie"
      res = g.srv.get("/", g.cookie.merge({flash.name => flash.value}))
      res.status_code.should eq 200
      body = HTML.unescape(res.body)
      ["Ausgabe „Wochenmarkt“ angelegt.", "Diese Woche", "Wochenmarkt",
       "Bezahlt von <strong>Anna</strong> für <strong>Anna</strong>, <strong>Ben</strong>, <strong>Cleo</strong>",
       "30,00 €", "Dein Saldo", "20,00 €", %(href="/ausgaben/neu")].each { |want| body.should contain want }
    end
  end

  describe "validation" do
    {
      "no title"             => {->(v : URI::Params, g : ExpenseGroup) { v["titel"] = " " }, "Bitte einen Titel angeben."},
      "broken amount"        => {->(v : URI::Params, g : ExpenseGroup) { v["betrag"] = "12,3,4" }, "Ungültiger Betrag"},
      "amount 0"             => {->(v : URI::Params, g : ExpenseGroup) { v["betrag"] = "0" }, "größer als 0"},
      "missing date"         => {->(v : URI::Params, g : ExpenseGroup) { v["datum"] = "" }, "Bitte ein Datum angeben."},
      "nobody"               => {->(v : URI::Params, g : ExpenseGroup) { v.delete_all("teil"); nil }, "mindestens eine Person"},
      "wrong percent"        => {->(v : URI::Params, g : ExpenseGroup) {
        v["aufteilung"] = "percent"
        v["wert_#{g.anna}"] = "50"
        v["wert_#{g.ben}"] = "20"
        v["wert_#{g.cleo}"] = "20"
      }, "100 %"},
      "wrong amounts" => {->(v : URI::Params, g : ExpenseGroup) {
        v["aufteilung"] = "amount"
        v["wert_#{g.anna}"] = "10"
      }, "zusammen 30,00 € ergeben"},
      "shares not an integer" => {->(v : URI::Params, g : ExpenseGroup) {
        v["aufteilung"] = "shares"
        v["wert_#{g.ben}"] = "1,5"
      }, "Ben: Anteile müssen ganze Zahlen sein"},
      "reimbursement to two" => {->(v : URI::Params, g : ExpenseGroup) { v["rueckzahlung"] = "1" }, "genau eine Person"},
      "broken currency"      => {->(v : URI::Params, g : ExpenseGroup) {
        v["waehrung"] = ""
        v["waehrung_andere"] = "EURO"
      }, "Ungültige Währung"},
    }.each do |name, (change, want)|
      it "rejects #{name} and keeps the inputs" do
        with_expense_group do |g|
          v = g.form
          v["titel"] = "Mein Titel"
          v["notiz"] = "Bitte behalten"
          change.call(v, g)
          status, _, body = g.post("/ausgaben/neu", v)
          status.should eq 422
          error_of(body).should contain want
          body.should contain "Bitte behalten</textarea>"
          body.should contain %(value="Mein Titel") if v["titel"] == "Mein Titel"
          g.store.list_expenses.should be_empty
        end
      end
    end
  end

  it "rejects a broken form encoding" do
    with_expense_group do |g|
      headers = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}
      res = g.srv.request("POST", "/ausgaben/neu", "titel=%zz&betrag=1", headers, g.cookie)
      res.status_code.should eq 400
      res.body.should contain "Ungültige Anfrage."
      g.srv.request("POST", "/ausgaben/neu?a=1;b=2", "titel=x", headers, g.cookie).status_code.should eq 400
      g.srv.request("POST", "/ausgaben/neu", "titel=x%2", headers, g.cookie).status_code.should eq 400
      g.srv.request("POST", "/ausgaben/neu", "titel=x%20y", headers, g.cookie).status_code.should eq 422
    end
  end

  it "edits and deletes an expense" do
    with_expense_group do |g|
      e = g.create(g.form)
      path = "/ausgaben/#{e.id}"

      status, body = g.get(path)
      status.should eq 200
      [%(value="Einkauf"), %(value="30,00"), "Ausgabe bearbeiten", "/einstellungen/wiederkehrend/neu?ausgabe=#{e.id}"].each do |want|
        body.should contain want
      end

      # Change amount and split.
      v = g.form
      v["betrag"] = "45,00"
      v["aufteilung"] = "shares"
      v["wert_#{g.anna}"] = "1"
      v["wert_#{g.ben}"] = "2"
      v.delete_all("teil")
      v.add("teil", g.anna.to_s)
      v.add("teil", g.ben.to_s)
      status, loc, body = g.post(path, v)
      {status, loc}.should eq({303, "/"}), error_of(body)
      got = g.store.get_expense(e.id)
      got.amount_cents.should eq 4500
      got.shares.size.should eq 2
      shares_of(got)[g.ben].should eq 3000
      status, body = g.get(path)
      status.should eq 200
      body.should contain %(name="wert_#{g.ben}" value="2")
      body.should contain "geändert"
      body.should contain "<del>30,00 €</del> → <ins>45,00 €</ins>"

      # An error while editing: 422, nothing changed.
      v["betrag"] = ""
      g.post(path, v)[0].should eq 422

      status, loc, _ = g.post("#{path}/loeschen")
      {status, loc}.should eq({303, "/"})
      g.store.get_expense(e.id).deleted?.should be_true
      status, body = g.get(path)
      status.should eq 200
      body.should contain "Gelöschte Ausgabe"
      body.should contain %(<fieldset class="stack" disabled>)
      g.post(path, g.form)[0].should eq 409
      g.post("#{path}/loeschen")[0].should eq 404
      g.get("/ausgaben/999")[0].should eq 404
      g.get("/ausgaben/abc")[0].should eq 404
      g.get("/")[1].should_not contain "Einkauf"
    end
  end

  it "handles foreign currencies" do
    with_expense_group(FakeFX.new({"USD" => 1.25, "JPY" => 160.0})) do |g|
      # No rate in the form: the rate comes from FX.
      v = g.form
      v["waehrung"] = "USD"
      v["betrag"] = "10,00"
      e = g.create(v)
      {e.original_currency, e.original_amount_minor, e.fx_rate, e.fx_source, e.amount_cents}
        .should eq({"USD", 1000, 1.25, Domain::FX_SOURCE_ECB, 800})

      # A rate entered by hand is manual; "other" currency with an ISO code.
      v = g.form
      v["waehrung"] = ""
      v["waehrung_andere"] = "thb"
      v["betrag"] = "100"
      v["kurs"] = "40"
      e = g.create(v)
      {e.original_currency, e.fx_rate, e.fx_source, e.amount_cents}.should eq({"THB", 40.0, Domain::FX_SOURCE_MANUAL, 250})

      # An ECB rate taken over from the form stays "ezb".
      v = g.form
      v["waehrung"] = "JPY"
      v["betrag"] = "1600"
      v["kurs"] = "160"
      v["kurs_quelle"] = "ezb"
      e = g.create(v)
      {e.original_amount_minor, e.amount_cents, e.fx_source}.should eq({1600, 1000, Domain::FX_SOURCE_ECB})

      # No rate available: an understandable message.
      v = g.form
      v["waehrung"] = "CHF"
      v["betrag"] = "10"
      status, _, body = g.post("/ausgaben/neu", v)
      status.should eq 422
      error_of(body).should contain "Kurs bitte von Hand eintragen"

      # By amounts in a foreign currency: amounts in USD, stored in euro cents.
      v = g.form
      v["waehrung"] = "USD"
      v["betrag"] = "10,00"
      v["kurs"] = "1,5"
      v["aufteilung"] = "amount"
      v.delete_all("teil")
      v.add("teil", g.anna.to_s)
      v.add("teil", g.ben.to_s)
      v["wert_#{g.anna}"] = "6,00"
      v["wert_#{g.ben}"] = "4"
      e = g.create(v)
      e.amount_cents.should eq 667
      shares_of(e).should eq({g.anna => 400, g.ben => 267})
      # The edit form shows the amounts in USD again.
      _, body = g.get("/ausgaben/#{e.id}")
      body.should contain %(name="wert_#{g.anna}" value="6,00")
      body.should contain %(name="wert_#{g.ben}" value="4,00")
      body.should contain %(<option value="USD" selected>)
      body.should contain %(name="kurs" value="1,5")
      # A wrong sum in USD: the message is in USD.
      v["wert_#{g.ben}"] = "3"
      status, _, body = g.post("/ausgaben/neu", v)
      status.should eq 422
      error_of(body).should contain "10,00 USD"

      # The list shows the original amount in small print.
      _, body = g.get("/")
      body.should contain "10,00 USD"
      body.should contain "8,00 €"
      g.store.list_expenses.size.should eq 4
    end
  end

  it "asks for a manual rate without an FX service" do
    with_expense_group do |g|
      v = g.form
      v["waehrung"] = "USD"
      v["betrag"] = "10"
      status, _, body = g.post("/ausgaben/neu", v)
      status.should eq 422
      error_of(body).should contain "Kurs bitte von Hand eintragen"
    end
  end

  it "prefills a reimbursement from the balances suggestion" do
    with_expense_group do |g|
      g.create(g.form) # Anna pays 30 € for everyone: Ben and Cleo owe 10 € each.

      status, body = g.get("/salden")
      status.should eq 200
      body.should contain "<strong>Ben</strong> schuldet <strong>Anna</strong>"
      link = "/ausgaben/neu?an=#{g.anna}&betrag=1000&rueckzahlung=1&von=#{g.ben}"
      body.should contain %(href="#{link}")

      status, body = g.get(link)
      status.should eq 200
      body.should contain %(id="rueckzahlung" name="rueckzahlung" value="1" checked)
      body.should contain %(value="Rückzahlung")
      body.should contain %(value="10,00")
      body.should contain %(<option value="#{g.ben}" selected>Ben)
      body.should contain %(name="teil" value="#{g.anna}" checked)
      body.should_not contain %(name="teil" value="#{g.cleo}" checked)

      v = URI::Params.new
      {"titel" => "Rückzahlung", "datum" => "2026-10-01", "waehrung" => "EUR", "betrag" => "10,00",
       "bezahlt_von" => g.ben.to_s, "rueckzahlung" => "1", "aufteilung" => "shares", "teil" => g.anna.to_s}.each { |k, val| v[k] = val }
      e = g.create(v)
      e.reimbursement?.should be_true
      e.split_mode.should eq Domain::SPLIT_EQUAL
      e.paid_by.should eq g.ben
      shares_of(e)[g.anna].should eq 1000
      b = g.store.balances
      {b[g.anna], b[g.ben]? || 0, b[g.cleo]}.should eq({1000, 0, -1000})
      _, body = g.get("/")
      body.should contain %(class="expense reimbursement")
      body.should contain "<strong>Ben</strong> an <strong>Anna</strong>"
      _, body = g.get("/salden")
      body.should_not contain "<strong>Ben</strong> schuldet"
      body.should contain "<strong>Cleo</strong> schuldet <strong>Anna</strong>"
    end
  end

  it "searches and filters the list" do
    with_expense_group do |g|
      cats = g.store.list_categories
      g.create(g.form)
      v = g.form
      v["titel"] = "Kinoabend"
      v["kategorie"] = cats[6].id.to_s # Freizeit
      v.delete_all("teil")
      v.add("teil", g.ben.to_s)
      g.create(v)
      v = g.form
      v["titel"] = "Bäckerei Ölmühle"
      g.create(v)

      [
        {"q=kino", "Kinoabend", ">Einkauf<"},
        {"q=" + URI.encode_www_form("BÄCKEREI ÖLMÜHLE"), "Bäckerei Ölmühle", "Kinoabend"},
        {"q=" + URI.encode_www_form("ölmühle"), "Bäckerei Ölmühle", "Kinoabend"},
        {"kategorie=#{g.food}", ">Einkauf<", "Kinoabend"},
        {"person=#{g.cleo}", ">Einkauf<", "Kinoabend"},
        {"q=gibtsnicht", "Keine Ausgaben gefunden", "Kinoabend"},
      ].each do |query, want, unwanted|
        status, body = g.get("/?" + query)
        status.should eq 200
        body.should contain want
        body.should_not contain unwanted
      end
      _, body = g.get("/?person=#{g.cleo}")
      body.should contain %(<option value="#{g.cleo}" selected>Cleo)
      body.should contain "Filter zurücksetzen"
      # Anna pays for "Kinoabend", Ben has the share.
      g.get("/?q=kino")[1].should contain "für <strong>Ben</strong>"
    end
  end

  it "pages the list with a link that keeps the filters" do
    with_expense_group do |g|
      input = Store::ExpenseInput.new(title: "Brot und Butter", date: date("2026-09-30"), paid_by: g.anna,
        amount_cents: 100, parts: [Domain::Part.new(g.anna)])
      (Zipfelkasse::Web::HOME_PAGE_SIZE + 1).times { g.store.create_expense(g.anna, input) }
      _, body = g.get("/?q=brot+und")
      body.scan(%(class="expense")).size.should eq Zipfelkasse::Web::HOME_PAGE_SIZE
      body.should contain %(href="/?anzahl=200&q=brot+und" data-more>Weitere anzeigen)
      _, body = g.get("/?anzahl=200&q=brot+und")
      body.scan(%(class="expense")).size.should eq Zipfelkasse::Web::HOME_PAGE_SIZE + 1
      body.should_not contain "Weitere anzeigen"
    end
  end

  # The JS preview distributes leftover cents by expense ID like the store;
  # for new expenses by the expected next ID.
  it "passes the rotation to the form" do
    with_expense_group do |g|
      e = g.create(g.form)
      g.get("/ausgaben/#{e.id}")[1].should contain %(data-rotation="#{e.id}")
      g.get("/ausgaben/neu")[1].should contain %(data-rotation="#{e.id + 1}")
    end
  end

  it "fills in defaults for a new expense" do
    with_expense_group do |g|
      g.store.set_participant_archived(0_i64, g.cleo, true)
      status, body = g.get("/ausgaben/neu")
      status.should eq 200
      [
        %(value="#{Store.format_date(g.srv.d.today)}"),
        %(<option value="#{g.anna}" selected>Anna),
        %(name="teil" value="#{g.anna}" checked),
        %(name="teil" value="#{g.ben}" checked),
        %(<option value="EUR" selected>),
        %(<option value="equal" selected>Gleichmäßig),
        "/static/expense-form.js?v=",
      ].each { |want| body.should contain want }
      body.should_not contain "Cleo"
    end
  end

  # "17.000" means 17000 (as for amounts).
  it "reads rates with thousands separators" do
    with_expense_group(FakeFX.new) do |g|
      v = g.form
      v["waehrung"] = "IDR"
      v["betrag"] = "170.000"
      v["kurs"] = "17.000"
      e = g.create(v)
      {e.original_amount_minor, e.fx_rate, e.amount_cents}.should eq({170000, 17000.0, 1000})
      v["kurs"] = "17.000,5"
      g.create(v).fx_rate.should eq 17000.5
      v["kurs"] = "0"
      status, _, body = g.post("/ausgaben/neu", v)
      status.should eq 422
      error_of(body).should contain "Wechselkurs"
    end
  end

  # As in the other modes and the JS preview, the tied cent goes round-robin
  # by expense ID over the people sorted by ID, regardless of their order in
  # the form (alphabetical: Adam before Zoe).
  it "breaks ties of foreign amounts by expense ID" do
    with_expense_group(FakeFX.new) do |g|
      zoe = must_participant(g.store, "Zoe")
      adam = must_participant(g.store, "Adam")
      v = g.form
      v["bezahlt_von"] = zoe.to_s
      v["waehrung"] = "USD"
      v["betrag"] = "10,00"
      v["kurs"] = "1,0857"
      v["aufteilung"] = "amount"
      v.delete_all("teil")
      v.add("teil", adam.to_s)
      v.add("teil", zoe.to_s)
      v["wert_#{zoe}"] = "5,00"
      v["wert_#{adam}"] = "5,00"
      2.times do
        e = g.create(v)
        want = {zoe => 460_i64, adam => 460_i64}
        want[[zoe, adam][e.id % 2]] = 461
        e.amount_cents.should eq 921
        shares_of(e).should eq want
      end
    end
  end

  # The edit form shows foreign amounts as entered (no lossy conversion back).
  it "keeps foreign split amounts as entered" do
    with_expense_group(FakeFX.new) do |g|
      v = g.form
      v["waehrung"] = "USD"
      v["betrag"] = "10,00"
      v["kurs"] = "1,1"
      v["aufteilung"] = "amount"
      v["wert_#{g.anna}"] = "3,33"
      v["wert_#{g.ben}"] = "3,33"
      v["wert_#{g.cleo}"] = "3,34"
      e = g.create(v)
      e.amount_cents.should eq 909
      shares_of(e).values.sum.should eq 909
      _, body = g.get("/ausgaben/#{e.id}")
      {g.anna => "3,33", g.ben => "3,33", g.cleo => "3,34"}.each do |p, want|
        body.should contain %(name="wert_#{p}" value="#{want}")
      end
      # Saving unchanged logs nothing.
      status, _, body = g.post("/ausgaben/#{e.id}", v)
      status.should eq(303), error_of(body)
      g.store.list_activity(Store::ActivityFilter.new(expense_id: e.id)).size.should eq 1
    end
  end

  it "saves a change of only the rate" do
    with_expense_group(FakeFX.new) do |g|
      v = g.form
      v["waehrung"] = "USD"
      v["betrag"] = "10,00"
      v["kurs"] = "1,25"
      e = g.create(v)
      v["kurs"] = "1,2501" # same euro cents, different rate
      status, _, body = g.post("/ausgaben/#{e.id}", v)
      status.should eq(303), error_of(body)
      got = g.store.get_expense(e.id)
      {got.fx_rate, got.amount_cents}.should eq({1.2501, 800})
      _, body = g.get("/ausgaben/#{e.id}")
      body.should contain "Kurs"
      body.should contain "1,2501"
    end
  end

  # Moving an instance to the date of another instance of the same
  # recurrence gives a message instead of a 500.
  it "reports a recurring collision in the form" do
    with_expense_group do |g|
      first = g.create(g.form)
      rid = g.store.create_recurring_from_expense(g.anna, first.id, Domain::FREQ_MONTHLY)
      input = first.input
      input.date = first.date.shift(months: 1)
      input.recurring_id = rid
      second = g.store.create_expense(0_i64, input)
      status, _, body = g.post("/ausgaben/#{second}", g.form) # date of the first instance
      status.should eq 422
      error_of(body).should contain "Für diesen Termin gibt es schon eine Ausgabe dieser Wiederholung."
    end
  end

  # Without JS, a rate left over from another currency (or date) would
  # otherwise be saved as an ECB rate.
  it "checks rates marked as ECB against the ECB rate" do
    with_expense_group(FakeFX.new({"USD" => 1.08, "GBP" => 0.85})) do |g|
      # A USD form with the ECB rate, then switched to GBP without JS.
      v = g.form
      v["waehrung"] = "GBP"
      v["betrag"] = "17,00"
      v["kurs"] = "1,08"
      v["kurs_quelle"] = Domain::FX_SOURCE_ECB
      e = g.create(v)
      {e.original_currency, e.fx_rate, e.fx_source, e.amount_cents}.should eq({"GBP", 0.85, Domain::FX_SOURCE_ECB, 2000})

      # The matching ECB rate is kept.
      v["kurs"] = "0,85"
      e = g.create(v)
      {e.fx_rate, e.fx_source}.should eq({0.85, Domain::FX_SOURCE_ECB})

      # Without a source a rate counts as manual and is kept.
      v["kurs"] = "1,08"
      v["kurs_quelle"] = ""
      e = g.create(v)
      {e.fx_rate, e.fx_source}.should eq({1.08, Domain::FX_SOURCE_MANUAL})

      # Switched to a currency without an ECB rate: a message, and the stale
      # rate is not offered again.
      v["waehrung"] = ""
      v["waehrung_andere"] = "THB"
      v["kurs"] = "0,85"
      v["kurs_quelle"] = Domain::FX_SOURCE_ECB
      status, _, body = g.post("/ausgaben/#{e.id}", v)
      status.should eq 422
      error_of(body).should contain "Kurs bitte von Hand eintragen"
      body.should contain %(name="kurs" value="")
      g.store.get_expense(e.id).original_currency.should eq "GBP"
    end
  end

  # Even if the ECB rate known today differs (e.g. published only later).
  it "keeps the saved ECB rate when saving unchanged" do
    fx = FakeFX.new({"USD" => 1.08})
    with_expense_group(fx) do |g|
      v = g.form
      v["waehrung"] = "USD"
      v["betrag"] = "10,80"
      e = g.create(v)
      fx.rates["USD"] = 1.2
      v["titel"] = "Einkauf USA"
      v["kurs"] = "1,08"
      v["kurs_quelle"] = Domain::FX_SOURCE_ECB
      status, _, body = g.post("/ausgaben/#{e.id}", v)
      status.should eq(303), error_of(body)
      got = g.store.get_expense(e.id)
      {got.fx_rate, got.amount_cents, got.fx_source, got.title}.should eq({1.08, 1000, Domain::FX_SOURCE_ECB, "Einkauf USA"})
    end
  end
end
