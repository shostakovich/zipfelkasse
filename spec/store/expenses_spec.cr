require "../spec_helper"

private def insert_recurring(store : Store, template : String, start : String, next_date : String) : Int64
  store.db.exec("INSERT INTO recurring (template_json, frequency, start_date, next_date, created_at, updated_at) " \
                "VALUES (?, 'monthly', ?, ?, 'x', 'x')", template, start, next_date).last_insert_id
end

describe "Store expenses" do
  use_household

  describe "creating an expense" do
    it "normalizes the title and stores the split, the payer and the category" do
      id = store.create_expense(household.anna, household.equal(" Einkauf  Rewe ", 1000, "2026-09-30", household.anna, household.anna, household.ben, household.cleo))

      expense = store.get_expense(id)
      expense.title.should eq "Einkauf Rewe"
      {expense.paid_by_name, expense.category_name, expense.date}.should eq({"Anna", "Lebensmittel", date("2026-09-30")})
      {expense.original_currency, expense.original_amount_minor, expense.fx_rate, expense.foreign?}.should eq({"EUR", 1000, 1.0, false})
      expense.parts.map(&.weight).should eq [1, 1, 1]
    end

    it "gives the extra cent to the person at the expense ID modulo the tied people" do
      id = store.create_expense(household.anna, household.equal("Einkauf", 1000, "2026-09-30", household.anna, household.anna, household.ben, household.cleo))

      expense = store.get_expense(id)
      {expense.share_of(household.anna), expense.share_of(household.ben), expense.share_of(household.cleo)}.should eq({333, 334, 333})
    end

    it "tells the hooks and logs the creation" do
      changes = [] of Store::ExpenseChange
      store.on_expense_change { |change| changes << change }

      id = store.create_expense(household.anna, household.equal("Einkauf Rewe", 1000, "2026-09-30", household.anna, household.anna))

      changes.should eq [Store::ExpenseChange.new(id, Store::Action::ExpenseCreated)]
      entry = store.list_activity(Store::ActivityFilter.new(expense_id: id)).first
      {entry.action, entry.actor_id, entry.actor_name, entry.expense_id}.should eq({Store::Action::ExpenseCreated, household.anna, "Anna", id})
      {entry.details.title, entry.details.amount_cents}.should eq({"Einkauf Rewe", 1000})
    end

    it "keeps the expense and logs the error when a hook fails" do
      store.on_expense_change { |_| raise "hook broke" }

      id = household.create(household.equal("Kino", 1000, "2026-09-01", household.anna, household.anna))

      store.get_expense(id).title.should eq "Kino"
      SPEC_LOG.to_s.should contain %(level=ERROR msg="expense change hook failed" expense_id=#{id} err="hook broke")
    end

    it "does not know an expense that was never created" do
      expect_raises(Store::NotFound) { store.get_expense(999_i64) }
    end

    it "predicts the ID of the next expense, also after a deletion" do
      store.next_expense_id.should eq 1
      id = household.create(household.equal("Kaffee", 300, "2026-09-01", household.anna, household.anna))
      store.delete_expense(household.anna, id)

      store.next_expense_id.should eq id + 1
      household.create(household.equal("Tee", 300, "2026-09-01", household.anna, household.anna)).should eq id + 1
    end
  end

  describe "validating an expense" do
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

  it "counts a line break of the notes (CR LF from a browser) as one character" do
    input = household.equal("Einkauf", 1000, "2026-08-01", household.anna, household.anna)
    input.notes = "a\r\n" * 999 + "aa"
    store.create_expense(household.anna, input)

    input.notes += "a"
    expect_invalid("Die Notiz ist zu lang (höchstens 2000 Zeichen).") { store.create_expense(household.anna, input) }
  end

  describe "updating an expense" do
    expense_id = 0_i64

    before_each do
      expense_id = household.create(household.equal("Pizza", 3000, "2026-09-01", household.anna, household.anna, household.ben))
    end

    it "logs nothing and tells no hook when it is saved unchanged" do
      changes = [] of Store::ExpenseChange
      store.on_expense_change { |change| changes << change }

      store.update_expense(household.ben, expense_id, store.get_expense(expense_id).to_input)

      changes.should be_empty
      store.list_activity(Store::ActivityFilter.new(expense_id: expense_id)).size.should eq 1
    end

    it "stores the new values and recomputes the shares" do
      input = store.get_expense(expense_id).to_input
      input.title = "Pizza & Wein"
      input.amount_cents = 4500
      input.split_mode = Domain::SplitMode::Shares
      input.parts = [Domain::Part.new(household.anna, 2), Domain::Part.new(household.ben, 1)]
      input.category_id = nil
      store.update_expense(household.ben, expense_id, input)

      expense = store.get_expense(expense_id)
      {expense.title, expense.amount_cents, expense.share_of(household.anna), expense.share_of(household.ben), expense.category_id, expense.category_name}
        .should eq({"Pizza & Wein", 4500, 3000, 1500, nil, nil})
    end

    it "tells the hooks and lists each changed field with its old and new value" do
      changes = [] of Store::ExpenseChange
      store.on_expense_change { |change| changes << change }
      input = store.get_expense(expense_id).to_input
      input.amount_cents = 4500
      input.split_mode = Domain::SplitMode::Shares
      input.parts = [Domain::Part.new(household.anna, 2), Domain::Part.new(household.ben, 1)]
      input.category_id = nil
      store.update_expense(household.ben, expense_id, input)

      changes.map(&.action).should eq [Store::Action::ExpenseUpdated]
      entry = store.list_activity(Store::ActivityFilter.new(expense_id: expense_id)).first
      {entry.action, entry.actor_name}.should eq({Store::Action::ExpenseUpdated, "Ben"})
      fields = entry.details.changes.to_h { |change| {change.field, change} }
      {fields["Betrag"].old, fields["Betrag"].new}.should eq({"30,00 €", "45,00 €"})
      {fields["Kategorie"].old, fields["Kategorie"].new}.should eq({"Lebensmittel", "–"})
      fields["Aufteilung"].new.should start_with "Nach Anteilen: Anna 30,00 €"
      fields.has_key?("Datum").should be_false
    end

    it "does not know an expense that was never created" do
      expect_raises(Store::NotFound) { store.update_expense(household.ben, 999_i64, store.get_expense(expense_id).to_input) }
    end

    it "keeps rotating the extra cent with the expense ID" do
      people = [household.anna, household.ben]
      extra = Hash(Int64, Int32).new(0)
      4.times do
        id = household.create(household.equal("Kaffee", 301, "2026-09-01", household.anna, household.ben, household.anna))
        expense = store.get_expense(id)
        lucky = people[id % 2]
        expense.share_of(lucky).should eq 151
        extra[lucky] += 1

        input = expense.to_input
        input.amount_cents = 501
        store.update_expense(household.anna, id, input)
        store.get_expense(id).share_of(lucky).should eq 251
      end
      extra.should eq({household.anna => 2, household.ben => 2})
    end
  end

  describe "deleting an expense" do
    expense_id = 0_i64

    before_each do
      expense_id = household.create(household.equal("Bahn", 5000, "2026-09-02", household.anna, household.anna, household.ben))
    end

    it "keeps it as deleted, out of the list and the balances" do
      store.delete_expense(household.ben, expense_id)

      store.get_expense(expense_id).deleted?.should be_true
      store.list_expenses.should be_empty
      store.balances.should be_empty
    end

    it "tells the hooks and logs the deletion" do
      changes = [] of Store::ExpenseChange
      store.on_expense_change { |change| changes << change }

      store.delete_expense(household.ben, expense_id)

      changes.should eq [Store::ExpenseChange.new(expense_id, Store::Action::ExpenseDeleted)]
      entry = store.list_activity(Store::ActivityFilter.new(limit: 1)).first
      {entry.action, entry.details.title}.should eq({Store::Action::ExpenseDeleted, "Bahn"})
    end

    it "refuses to delete or update a deleted expense" do
      store.delete_expense(household.ben, expense_id)

      expect_raises(Store::NotFound) { store.delete_expense(household.ben, expense_id) }
      expect_raises(Store::NotFound) { store.update_expense(household.ben, expense_id, store.get_expense(expense_id).to_input) }
    end
  end

  describe "listing expenses" do
    before_each do
      household.create(household.equal("Rewe Einkauf", 1000, "2026-09-01", household.anna, household.anna, household.ben))
      household.create(household.equal("Kino 100%", 2000, "2026-09-15", household.ben, household.ben, household.cleo))
      input = household.equal("Tanken", 3000, "2026-10-01", household.cleo, household.cleo)
      input.category_id = nil
      input.notes = "Rewe-Tankstelle"
      household.create(input)
    end

    {
      "newest first"                           => {Store::ExpenseFilter.new, ["Tanken", "Kino 100%", "Rewe Einkauf"]},
      "oldest first"                           => {Store::ExpenseFilter.new(sort: Store::ExpenseSort::DateAsc), ["Rewe Einkauf", "Kino 100%", "Tanken"]},
      "most expensive first"                   => {Store::ExpenseFilter.new(sort: Store::ExpenseSort::AmountDesc), ["Tanken", "Kino 100%", "Rewe Einkauf"]},
      "cheapest first"                         => {Store::ExpenseFilter.new(sort: Store::ExpenseSort::AmountAsc), ["Rewe Einkauf", "Kino 100%", "Tanken"]},
      "from the second entry on, at most one"  => {Store::ExpenseFilter.new(limit: 1, offset: 1), ["Kino 100%"]},
      "with a text in the title or the notes"  => {Store::ExpenseFilter.new(text: "rewe"), ["Tanken", "Rewe Einkauf"]},
      "with a text that holds a LIKE wildcard" => {Store::ExpenseFilter.new(text: "100%"), ["Kino 100%"]},
      "in a date range"                        => {Store::ExpenseFilter.new(from: date("2026-09-01"), to: date("2026-09-15")), ["Kino 100%", "Rewe Einkauf"]},
      "in an amount range"                     => {Store::ExpenseFilter.new(min_cents: 1500, max_cents: 2500), ["Kino 100%"]},
      "without a category"                     => {Store::ExpenseFilter.new(without_category: true), ["Tanken"]},
    }.each do |name, (filter, titles)|
      it "lists the expenses #{name}" do
        found = store.list_expenses(filter)

        found.map(&.title).should eq titles
        found.each { |expense| expense.shares.should_not be_empty }
      end
    end

    it "lists the expenses of a category" do
      store.list_expenses(Store::ExpenseFilter.new(category_id: household.food)).map(&.title).should eq ["Kino 100%", "Rewe Einkauf"]
    end

    it "lists the expenses a person paid or shares" do
      store.list_expenses(Store::ExpenseFilter.new(participant_id: household.cleo)).map(&.title).should eq ["Tanken", "Kino 100%"]
    end
  end

  describe "searching a text" do
    ids = {} of String => Int64

    before_each do
      {"lower" => {"bäckerei am markt", ""}, "upper" => {"BÄCKER SCHMIDT", ""}, "mixed" => {"Brötchen", "vom Bäcker"},
       "street" => {"Parken Hauptstraße", ""}, "caps" => {"PARKHAUS HAUPTSTRASSE", ""}, "ascii" => {"Baecker ohne Umlaut", ""}}.each do |key, (title, notes)|
        input = household.equal(title, 1000, "2026-09-01", household.anna, household.anna, household.ben)
        input.notes = notes
        ids[key] = household.create(input)
      end
    end

    {
      "BÄCKER" => %w(mixed upper lower), "bäcker" => %w(mixed upper lower), "Bäckerei" => %w(lower),
      "brötchen" => %w(mixed), "BRÖTCHEN" => %w(mixed), "straße" => %w(caps street), "STRASSE" => %w(caps street),
      "ẞ" => %w(caps street),
    }.each do |text, expected|
      it "finds #{expected.join(", ")} for #{text.inspect} regardless of the case of umlauts and ß" do
        store.list_expenses(Store::ExpenseFilter.new(text: text)).map(&.id).should eq expected.map { |key| ids[key] }
      end
    end
  end

  it "computes the balances with a reimbursement" do
    store.create_expense(household.anna, household.equal("Essen", 3000, "2026-09-01", household.anna, household.anna, household.ben, household.cleo))
    paid_back = store.get_expense(store.create_expense(household.ben, household.reimbursement(1000, "2026-09-02", household.ben, household.anna)))

    {paid_back.reimbursement?, paid_back.split_mode, paid_back.share_of(household.anna)}.should eq({true, Domain::SplitMode::Equal, 1000})
    balances = store.balances
    {balances[household.anna], balances[household.ben], balances[household.cleo]}.should eq({1000, 0, -1000})
  end

  describe "instances of a recurring expense" do
    rule_id = 0_i64

    before_each do
      rule_id = insert_recurring(store, "{}", "2026-01-31", "2026-02-28")
    end

    it "allows only one per date, and logs it as entered by the system" do
      input = household.equal("Miete", 100000, "2026-01-31", household.anna, household.anna, household.ben)
      input.recurring_id = rule_id
      entries = store.list_activity.size
      store.create_expense(nil, input)

      expect_raises(Store::RecurringExists) { store.create_expense(nil, input) }

      activities = store.list_activity
      activities.size.should eq entries + 1
      {activities[0].actor_id, activities[0].actor_name}.should eq({nil, nil})
    end

    it "are refused for a paused or deleted rule" do
      store.db.exec("UPDATE recurring SET active = 0 WHERE id = ?", rule_id)
      input = household.equal("Miete", 100000, "2026-01-31", household.anna, household.anna, household.ben)
      input.recurring_id = rule_id
      expect_raises(Store::RecurringChanged) { store.create_expense(nil, input) }

      input.recurring_id = 999
      expect_raises(Store::RecurringChanged) { store.create_expense(nil, input) }
    end

    it "cannot be moved onto the date of another instance, which is an input error" do
      input = household.equal("Miete", 100000, "2026-01-31", household.anna, household.anna, household.ben)
      input.recurring_id = rule_id
      store.create_expense(nil, input)
      input.date = date("2026-02-28")
      second = store.create_expense(nil, input)

      input.date = date("2026-01-31")
      expect_invalid("Für diesen Termin gibt es schon eine Ausgabe dieser Wiederholung.") { store.update_expense(household.anna, second, input) }
    end
  end
end
