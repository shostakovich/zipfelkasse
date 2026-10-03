require "../spec_helper"

private def ids(expenses : Array(Store::Expense)) : Array(Int64)
  expenses.map(&.id)
end

private def insert_recurring(store : Store, template : String, start : String, next_date : String) : Int64
  store.db.exec("INSERT INTO recurring (template_json, frequency, start_date, next_date, created_at, updated_at) " \
                "VALUES (?, 'monthly', ?, ?, 'x', 'x')", template, start, next_date).last_insert_id
end

describe "Store expenses" do
  use_household

  it "creates and reads an expense" do
    h = household
    events = [] of Store::ExpenseChange
    store.on_expense_change { |c| events << c }

    id = store.create_expense(h.anna, h.equal(" Einkauf  Rewe ", 1000, "2026-09-30", h.anna, h.anna, h.ben, h.cleo))
    e = store.get_expense(id)
    e.title.should eq "Einkauf Rewe"
    e.paid_by_name.should eq "Anna"
    e.category_name.should eq "Lebensmittel"
    e.date.should eq date("2026-09-30")
    {e.original_currency, e.original_amount_minor, e.fx_rate, e.foreign?}.should eq({"EUR", 1000, 1.0, false})
    # Expense 1: the extra cent goes to index 1 mod 3 of the tied people (Ben).
    e.shares.size.should eq 3
    {e.share_of(h.anna), e.share_of(h.ben), e.share_of(h.cleo)}.should eq({333, 334, 333})
    e.parts.size.should eq 3
    e.parts[0].weight.should eq 1
    events.should eq [Store::ExpenseChange.new(id, Store::Action::ExpenseCreated)]

    acts = store.list_activity(Store::ActivityFilter.new(expense_id: id))
    acts.size.should eq 1
    a = acts[0]
    {a.action, a.actor_id, a.actor_name, a.expense_id}.should eq({Store::Action::ExpenseCreated, h.anna, "Anna", id})
    {a.details.title, a.details.amount_cents}.should eq({"Einkauf Rewe", 1000})
    expect_raises(Store::NotFound) { store.get_expense(999_i64) }
  end

  describe "validation" do
    {
      "without a title"                     => {"Bitte einen Titel angeben.", ->(i : Store::ExpenseInput) { i.title = " "; i }},
      "without a date"                      => {"Bitte ein Datum angeben.", ->(i : Store::ExpenseInput) { i.date = nil; i }},
      "without a payer"                     => {"Bitte angeben, wer bezahlt hat.", ->(i : Store::ExpenseInput) { i.paid_by = 0; i }},
      "with a title over 200 characters"    => {"Der Titel ist zu lang (höchstens 200 Zeichen).", ->(i : Store::ExpenseInput) { i.title = "x" * 201; i }},
      "with a note over 2000 characters"    => {"Die Notiz ist zu lang (höchstens 2000 Zeichen).", ->(i : Store::ExpenseInput) { i.notes = "ä" * 2001; i }},
      "with the amount 0"                   => {"Der Betrag muss größer als 0 sein.", ->(i : Store::ExpenseInput) { i.amount_cents = 0; i }},
      "without anybody sharing it"          => {"Mindestens eine Person muss an der Ausgabe beteiligt sein.", ->(i : Store::ExpenseInput) { i.parts = [] of Domain::Part; i }},
      "with an unknown payer"               => {"Unbekannte Person in der Ausgabe.", ->(i : Store::ExpenseInput) { i.paid_by = 999; i }},
      "with an unknown person in the split" => {"Unbekannte Person in der Ausgabe.", ->(i : Store::ExpenseInput) { i.parts = i.parts + [Domain::Part.new(999)]; i }},
      "with an unknown category"            => {"Unbekannte Kategorie.", ->(i : Store::ExpenseInput) { i.category_id = 999; i }},
      "with percentages that do not add up" => {"Die Prozente müssen zusammen 100 % ergeben (aktuell 50,00 %).", ->(i : Store::ExpenseInput) {
        i.split_mode = Domain::SplitMode::Percent
        i.parts = [Domain::Part.new(1, 5000)]
        i
      }},
      "in a foreign currency without a rate" => {"Bitte einen Wechselkurs für USD angeben.", ->(i : Store::ExpenseInput) {
        i.original_currency, i.original_amount_minor = "USD", 2200_i64
        i
      }},
      "in a foreign currency without an amount" => {"Bitte den Betrag in USD angeben.", ->(i : Store::ExpenseInput) {
        i.original_currency, i.fx_rate = "USD", 1.1
        i
      }},
      "in a currency with an invalid code" => {"Ungültige Währung „U$D“.", ->(i : Store::ExpenseInput) {
        i.original_currency, i.original_amount_minor, i.fx_rate = "U$D", 2200_i64, 1.1
        i
      }},
      "in a currency with a two-letter code" => {"Ungültige Währung „US“.", ->(i : Store::ExpenseInput) {
        i.original_currency, i.original_amount_minor, i.fx_rate = "US", 2200_i64, 1.1
        i
      }},
      "as a reimbursement to two people" => {"Eine Rückzahlung geht an genau eine Person.", ->(i : Store::ExpenseInput) { i.reimbursement = true; i }},
      "as a reimbursement to oneself"    => {"Bei einer Rückzahlung müssen Zahler und Empfänger verschieden sein.", ->(i : Store::ExpenseInput) {
        i.reimbursement = true
        i.parts = [Domain::Part.new(1)]
        i
      }},
    }.each do |name, (message, change)|
      it "rejects an expense #{name}" do
        input = household.equal("Kino", 2000, "2026-09-01", household.anna, household.anna, household.ben)
        expect_invalid(message) { store.create_expense(household.anna, change.call(input)) }
        store.list_expenses.should be_empty
      end
    end
  end

  # Line breaks arrive as CR LF but count as one character in the form.
  it "limits notes to 2000 characters" do
    h = household
    input = h.equal("Einkauf", 1000, "2026-08-01", h.anna, h.anna)
    input.notes = "a\r\n" * 999 + "aa"
    store.create_expense(h.anna, input)
    input.notes += "a"
    expect_invalid("Die Notiz ist zu lang (höchstens 2000 Zeichen).") { store.create_expense(h.anna, input) }
  end

  it "updates an expense and logs the changes" do
    h = household
    id = store.create_expense(h.anna, h.equal("Pizza", 3000, "2026-09-01", h.anna, h.anna, h.ben))
    events = [] of Store::ExpenseChange
    store.on_expense_change { |c| events << c }

    e = store.get_expense(id)
    # Saving unchanged: no log entry, no hook.
    store.update_expense(h.ben, id, e.to_input)
    events.should be_empty

    input = e.to_input
    input.title = "Pizza & Wein"
    input.amount_cents = 4500
    input.split_mode = Domain::SplitMode::Shares
    input.parts = [Domain::Part.new(h.anna, 2), Domain::Part.new(h.ben, 1)]
    input.category_id = nil
    store.update_expense(h.ben, id, input)
    e = store.get_expense(id)
    {e.title, e.amount_cents, e.share_of(h.anna), e.share_of(h.ben), e.category_id, e.category_name}
      .should eq({"Pizza & Wein", 4500, 3000, 1500, nil, nil})
    events.map(&.action).should eq [Store::Action::ExpenseUpdated]

    acts = store.list_activity(Store::ActivityFilter.new(expense_id: id))
    acts.size.should eq 2
    {acts[0].action, acts[0].actor_name}.should eq({Store::Action::ExpenseUpdated, "Ben"})
    fields = acts[0].details.changes.to_h { |c| {c.field, c} }
    {fields["Betrag"].old, fields["Betrag"].new}.should eq({"30,00 €", "45,00 €"})
    {fields["Kategorie"].old, fields["Kategorie"].new}.should eq({"Lebensmittel", "–"})
    fields["Aufteilung"].new.should start_with "Nach Anteilen: Anna 30,00 €"
    fields.has_key?("Datum").should be_false

    expect_raises(Store::NotFound) { store.update_expense(h.ben, 999_i64, input) }
  end

  it "deletes an expense softly" do
    h = household
    id = store.create_expense(h.anna, h.equal("Bahn", 5000, "2026-09-02", h.anna, h.anna, h.ben))
    events = [] of Store::ExpenseChange
    store.on_expense_change { |c| events << c }

    store.delete_expense(h.ben, id)
    expect_raises(Store::NotFound) { store.delete_expense(h.ben, id) }
    e = store.get_expense(id)
    e.deleted?.should be_true
    expect_raises(Store::NotFound) { store.update_expense(h.ben, id, e.to_input) }
    store.list_expenses.should be_empty
    store.balances.should be_empty
    events.should eq [Store::ExpenseChange.new(id, Store::Action::ExpenseDeleted)]
    a = store.list_activity(Store::ActivityFilter.new(limit: 1))[0]
    {a.action, a.details.title}.should eq({Store::Action::ExpenseDeleted, "Bahn"})
  end

  it "filters expenses" do
    h = household
    a = h.create(h.equal("Rewe Einkauf", 1000, "2026-09-01", h.anna, h.anna, h.ben))
    b = h.create(h.equal("Kino 100%", 2000, "2026-09-15", h.ben, h.ben, h.cleo))
    input = h.equal("Tanken", 3000, "2026-10-01", h.cleo, h.cleo)
    input.category_id = nil
    input.notes = "Rewe-Tankstelle"
    c = h.create(input)

    {
      "all, newest first"          => {Store::ExpenseFilter.new, [c, b, a]},
      "text in title/notes"        => {Store::ExpenseFilter.new(text: "rewe"), [c, a]},
      "LIKE characters"            => {Store::ExpenseFilter.new(text: "100%"), [b]},
      "category"                   => {Store::ExpenseFilter.new(category_id: h.food), [b, a]},
      "without category"           => {Store::ExpenseFilter.new(without_category: true), [c]},
      "person pays or is involved" => {Store::ExpenseFilter.new(participant_id: h.cleo), [c, b]},
      "date range"                 => {Store::ExpenseFilter.new(from: date("2026-09-01"), to: date("2026-09-15")), [b, a]},
      "limit/offset"               => {Store::ExpenseFilter.new(limit: 1, offset: 1), [b]},
      "oldest first"               => {Store::ExpenseFilter.new(sort: Store::ExpenseSort::DateAsc), [a, b, c]},
      "largest first"              => {Store::ExpenseFilter.new(sort: Store::ExpenseSort::AmountDesc), [c, b, a]},
      "smallest first"             => {Store::ExpenseFilter.new(sort: Store::ExpenseSort::AmountAsc), [a, b, c]},
      "amount range"               => {Store::ExpenseFilter.new(min_cents: 1500, max_cents: 2500), [b]},
    }.each do |name, (filter, want)|
      es = store.list_expenses(filter)
      {name, ids(es)}.should eq({name, want})
      es.each { |e| e.shares.should_not be_empty }
    end
  end

  it "rotates the extra cent with the expense ID, also after an update" do
    h = household
    people = [h.anna, h.ben]
    extra = Hash(Int64, Int32).new(0)
    4.times do
      id = store.create_expense(h.anna, h.equal("Kaffee", 301, "2026-09-01", h.anna, h.ben, h.anna))
      e = store.get_expense(id)
      want = people[id % 2]
      e.share_of(want).should eq 151
      extra[want] += 1

      input = e.to_input
      input.amount_cents = 501
      store.update_expense(h.anna, id, input)
      store.get_expense(id).share_of(want).should eq 251
    end
    extra.should eq({h.anna => 2, h.ben => 2})
  end

  it "predicts the next expense ID" do
    h = household
    store.next_expense_id.should eq 1
    id = h.create(h.equal("Kaffee", 300, "2026-09-01", h.anna, h.anna))
    store.delete_expense(h.anna, id)
    store.next_expense_id.should eq id + 1
    h.create(h.equal("Tee", 300, "2026-09-01", h.anna, h.anna)).should eq id + 1
  end

  it "searches text ignoring the case of umlauts" do
    h = household
    mk = ->(title : String, notes : String) do
      input = h.equal(title, 1000, "2026-09-01", h.anna, h.anna, h.ben)
      input.notes = notes
      store.create_expense(h.anna, input)
    end
    lower = mk.call("bäckerei am markt", "")
    upper = mk.call("BÄCKER SCHMIDT", "")
    mixed = mk.call("Brötchen", "vom Bäcker")
    street = mk.call("Parken Hauptstraße", "")
    caps = mk.call("PARKHAUS HAUPTSTRASSE", "")
    mk.call("Baecker ohne Umlaut", "")

    {
      "BÄCKER"   => [mixed, upper, lower],
      "bäcker"   => [mixed, upper, lower],
      "Bäckerei" => [lower],
      "brötchen" => [mixed],
      "BRÖTCHEN" => [mixed],
      "straße"   => [caps, street],
      "STRASSE"  => [caps, street],
      "ẞ"        => [caps, street],
    }.each do |text, want|
      {text, ids(store.list_expenses(Store::ExpenseFilter.new(text: text)))}.should eq({text, want})
    end
  end

  it "computes balances with a reimbursement" do
    h = household
    store.create_expense(h.anna, h.equal("Essen", 3000, "2026-09-01", h.anna, h.anna, h.ben, h.cleo))
    # Ben pays Anna back 10 €.
    r = Store::ExpenseInput.new(title: "Rückzahlung", date: date("2026-09-02"), paid_by: h.ben, reimbursement: true,
      amount_cents: 1000, parts: [Domain::Part.new(h.anna)])
    e = store.get_expense(store.create_expense(h.ben, r))
    {e.reimbursement?, e.split_mode, e.share_of(h.anna)}.should eq({true, Domain::SplitMode::Equal, 1000})
    b = store.balances
    {b[h.anna], b[h.ben], b[h.cleo]}.should eq({1000, 0, -1000})
  end

  it "rejects a second instance of a recurrence on the same date" do
    h = household
    rid = insert_recurring(store, "{}", "2026-01-31", "2026-02-28")
    input = h.equal("Miete", 100000, "2026-01-31", h.anna, h.anna, h.ben)
    input.recurring_id = rid
    before = store.list_activity.size
    store.create_expense(nil, input)
    expect_raises(Store::RecurringExists) { store.create_expense(nil, input) }
    acts = store.list_activity
    acts.size.should eq before + 1
    {acts[0].actor_id, acts[0].actor_name}.should eq({nil, nil})
  end

  it "rejects an instance of a paused or deleted recurrence" do
    h = household
    rid = insert_recurring(store, "{}", "2026-01-31", "2026-02-28")
    store.db.exec("UPDATE recurring SET active = 0 WHERE id = ?", rid)
    input = h.equal("Miete", 100000, "2026-01-31", h.anna, h.anna, h.ben)
    input.recurring_id = rid
    expect_raises(Store::RecurringChanged) { store.create_expense(nil, input) }
    input.recurring_id = 999
    expect_raises(Store::RecurringChanged) { store.create_expense(nil, input) }
  end

  # An input error, not a 500.
  it "rejects moving an instance onto the date of another instance" do
    h = household
    rid = insert_recurring(store, "{}", "2026-01-31", "2026-03-31")
    input = h.equal("Miete", 100000, "2026-01-31", h.anna, h.anna, h.ben)
    input.recurring_id = rid
    store.create_expense(nil, input)
    input.date = date("2026-02-28")
    second = store.create_expense(nil, input)
    input.date = date("2026-01-31")
    expect_invalid("Für diesen Termin gibt es schon eine Ausgabe dieser Wiederholung.") { store.update_expense(h.anna, second, input) }
  end

  it "logs a failing expense-change hook and keeps the change" do
    h = household
    store.on_expense_change { |_| raise "hook broke" }
    id = h.create(h.equal("Kino", 1000, "2026-09-01", h.anna, h.anna))
    store.get_expense(id).title.should eq "Kino"
    SPEC_LOG.to_s.should contain %(level=ERROR msg="expense change hook failed" expense_id=#{id} err="hook broke")
  end
end
