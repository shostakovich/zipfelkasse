require "file_utils"
require "./expense_fixture"

private alias Store = Zipfelkasse::Store
private alias Domain = Zipfelkasse::Domain

private def with_temp_dir(&)
  dir = File.tempname("zipfelkasse-spec")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def ids(es : Array(Store::Expense)) : Array(Int64)
  es.map(&.id)
end

private def weights(e : Store::Expense) : Array(Int64)
  e.parts.map(&.weight)
end

private def field_changes(s : Store, expense_id : Int64) : Hash(String, Store::FieldChange)
  acts = s.list_activity(Store::ActivityFilter.new(expense_id: expense_id, limit: 1))
  return {} of String => Store::FieldChange unless acts.size == 1 && acts[0].action == Store::Action::ExpenseUpdated
  acts[0].details.changes.to_h { |c| {c.field, c} }
end

private def insert_recurring(s : Store, template : String, start : String, next_date : String) : Int64
  s.db.exec("INSERT INTO recurring (template_json, frequency, start_date, next_date, created_at, updated_at) " \
            "VALUES (?, 'monthly', ?, ?, 'x', 'x')", template, start, next_date).last_insert_id
end

private def leave_transaction_early(s : Store) : Nil
  s.transaction do |tx|
    tx.exec("UPDATE settings SET value = 'Weg' WHERE key = ?", Store::SETTING_GROUP_NAME)
    return
  end
end

describe Zipfelkasse::Store do
  it "migrates and seeds a new database" do
    with_store do |s|
      s.schema_version.should eq Store::LATEST_VERSION
      s.list_activity.should be_empty
      cats = s.list_categories
      cats.size.should eq 10
      cats.first.name.should eq "Lebensmittel"
      cats.last.name.should eq "Sonstiges"
      s.group_name.should eq "Zipfelkasse"
    end
  end

  it "rejects schema versions it cannot handle" do
    with_store do |s|
      [3, Store::LATEST_VERSION + 1].each do |version|
        s.db.exec("PRAGMA user_version = #{version}")
        expect_raises(Store::Error, /schema version #{version}/) { s.migrate }
      end
    end
  end

  it "applies migrations above the base version once" do
    with_store do |s|
      migrations = [{6, "ALTER TABLE settings ADD COLUMN note TEXT"}, {7, "UPDATE settings SET value = 'Neu'"}]
      2.times do
        s.migrate(migrations)
        s.schema_version.should eq 7
      end
      s.group_name.should eq "Neu"
    end
  end

  it "opens a file database twice" do
    with_temp_dir do |dir|
      path = File.join(dir, "sub", "zipfelkasse.db")
      s = Store.open(path)
      must_participant(s, "Anna")
      s.db.scalar("PRAGMA journal_mode").should eq "wal"
      s.db.scalar("PRAGMA foreign_keys").should eq 1
      s.close

      s = Store.open(path)
      s.list_participants.size.should eq 1
      s.close
    end
  end

  it "manages participants" do
    with_store do |s|
      anna = must_participant(s, "  Anna  ")
      ben = must_participant(s, "Ben")
      store_validation_error { s.create_participant(nil, "anna") }
      store_validation_error { s.create_participant(nil, "   ") }
      p = s.get_participant(anna)
      p.name.should eq "Anna"
      p.archived?.should be_false
      p.created_at.should_not be_nil

      s.rename_participant(nil, ben, "Benedikt")
      store_validation_error { s.rename_participant(nil, ben, "ANNA") }
      s.set_participant_archived(nil, ben, true)
      s.list_participants.size.should eq 1
      all = s.list_participants(true)
      all.size.should eq 2
      all[1].archived?.should be_true
      s.set_participant_archived(nil, ben, false)
      expect_raises(Store::NotFound) { s.get_participant(999_i64) }
      expect_raises(Store::NotFound) { s.rename_participant(nil, 999_i64, "X") }
    end
  end

  it "manages categories" do
    with_store do |s|
      id = s.create_category(nil, "Haustiere")
      cats = s.list_categories
      cats[-1].name.should eq "Sonstiges"
      cats[-2].id.should eq id
      store_validation_error { s.create_category(nil, "lebensmittel") }
      s.rename_category(nil, id, "Tiere")
      s.set_category_archived(nil, id, true)
      c = s.get_category(id)
      c.name.should eq "Tiere"
      c.archived?.should be_true
    end
  end

  it "stores settings" do
    with_store do |s|
      expect_raises(Store::NotFound) { s.get_setting("nix") }
      s.set_setting(Store::SETTING_GROUP_NAME, "WG Sonnenallee")
      s.set_setting(Store::SETTING_GROUP_NAME, "WG Sonnenallee 2")
      s.group_name.should eq "WG Sonnenallee 2"
    end
  end

  it "creates and reads an expense" do
    with_expense_fixture do |f|
      events = [] of Store::ExpenseChange
      f.s.on_expense_change { |c| events << c }

      id = f.s.create_expense(f.anna, f.equal(" Einkauf  Rewe ", 1000, "2026-09-30", f.anna, f.anna, f.ben, f.cleo))
      e = f.s.get_expense(id)
      e.title.should eq "Einkauf Rewe"
      e.paid_by_name.should eq "Anna"
      e.category_name.should eq "Lebensmittel"
      e.date.should eq date("2026-09-30")
      {e.original_currency, e.original_amount_minor, e.fx_rate, e.foreign?}.should eq({"EUR", 1000, 1.0, false})
      # Expense 1: the extra cent goes to index 1 mod 3 of the tied people (Ben).
      e.shares.size.should eq 3
      {e.share_of(f.anna), e.share_of(f.ben), e.share_of(f.cleo)}.should eq({333, 334, 333})
      e.parts.size.should eq 3
      e.parts[0].weight.should eq 1
      events.should eq [Store::ExpenseChange.new(id, Store::Action::ExpenseCreated)]

      acts = f.s.list_activity(Store::ActivityFilter.new(expense_id: id))
      acts.size.should eq 1
      a = acts[0]
      {a.action, a.actor_id, a.actor_name, a.expense_id}.should eq({Store::Action::ExpenseCreated, f.anna, "Anna", id})
      {a.details.title, a.details.amount_cents}.should eq({"Einkauf Rewe", 1000})
      expect_raises(Store::NotFound) { f.s.get_expense(999_i64) }
    end
  end

  it "rejects invalid expenses" do
    with_expense_fixture do |f|
      base = f.equal("Kino", 2000, "2026-09-01", f.anna, f.anna, f.ben)
      mods = {
        "without title"    => ->(i : Store::ExpenseInput) { i.title = " "; i },
        "without date"     => ->(i : Store::ExpenseInput) { i.date = nil; i },
        "without payer"    => ->(i : Store::ExpenseInput) { i.paid_by = 0; i },
        "note too long"    => ->(i : Store::ExpenseInput) { i.notes = "ä" * 2001; i },
        "amount 0"         => ->(i : Store::ExpenseInput) { i.amount_cents = 0; i },
        "no participants"  => ->(i : Store::ExpenseInput) { i.parts = [] of Domain::Part; i },
        "unknown payer"    => ->(i : Store::ExpenseInput) { i.paid_by = 999; i },
        "unknown person"   => ->(i : Store::ExpenseInput) { i.parts = i.parts + [Domain::Part.new(999)]; i },
        "unknown category" => ->(i : Store::ExpenseInput) { i.category_id = 999; i },
        "wrong percent"    => ->(i : Store::ExpenseInput) {
          i.split_mode = Domain::SplitMode::Percent
          i.parts = [Domain::Part.new(f.anna, 5000)]
          i
        },
        "foreign currency without rate"   => ->(i : Store::ExpenseInput) { i.original_currency = "USD"; i.original_amount_minor = 2200; i },
        "foreign currency without amount" => ->(i : Store::ExpenseInput) { i.original_currency = "USD"; i.fx_rate = 1.1; i },
        "invalid currency code"           => ->(i : Store::ExpenseInput) {
          i.original_currency, i.original_amount_minor, i.fx_rate = "U$D", 2200_i64, 1.1
          i
        },
        "two-letter currency code" => ->(i : Store::ExpenseInput) {
          i.original_currency, i.original_amount_minor, i.fx_rate = "US", 2200_i64, 1.1
          i
        },
        "reimbursement to two"     => ->(i : Store::ExpenseInput) { i.reimbursement = true; i },
        "reimbursement to oneself" => ->(i : Store::ExpenseInput) {
          i.reimbursement = true
          i.parts = [Domain::Part.new(f.anna)]
          i
        },
      }
      mods.each do |name, mod|
        rejected = begin
          f.s.create_expense(f.anna, mod.call(base))
          false
        rescue Domain::ValidationError
          true
        end
        {name, rejected}.should eq({name, true})
      end
      f.s.list_expenses.should be_empty
    end
  end

  # Deleted expenses do not count.
  it "archives a person only without a balance" do
    with_expense_fixture do |f|
      id = f.must_create(f.equal("Einkauf", 1000, "2026-08-01", f.anna, f.anna, f.ben))
      store_validation_error { f.s.set_participant_archived(nil, f.ben, true) }
        .should contain "Ben hat noch einen Saldo von -5,00 €"
      f.s.get_participant(f.ben).archived?.should be_false
      f.s.set_participant_archived(nil, f.cleo, true)
      expect_raises(Store::NotFound) { f.s.set_participant_archived(nil, 999_i64, true) }
      f.s.delete_expense(f.anna, id)
      f.s.set_participant_archived(nil, f.ben, true)
    end
  end

  # Line breaks arrive as CR LF but count as one character in the form.
  it "limits notes to 2000 characters" do
    with_expense_fixture do |f|
      input = f.equal("Einkauf", 1000, "2026-08-01", f.anna, f.anna)
      input.notes = "a\r\n" * 999 + "aa"
      f.s.create_expense(f.anna, input)
      input.notes += "a"
      store_validation_error { f.s.create_expense(f.anna, input) }.should contain "2000 Zeichen"
    end
  end

  it "stores a foreign currency" do
    with_expense_fixture do |f|
      input = f.equal("Diner NYC", Domain.to_eur_cents(10000, "USD", 1.0823), "2026-08-01", f.ben, f.anna, f.ben)
      input.original_currency, input.original_amount_minor, input.fx_rate, input.fx_source = "usd", 10000_i64, 1.0823, Domain::FXSource::Ecb
      e = f.s.get_expense(f.s.create_expense(f.ben, input))
      {e.foreign?, e.original_currency, e.amount_cents, e.fx_rate, e.fx_source}.should eq({true, "USD", 9240, 1.0823, Domain::FXSource::Ecb})
    end
  end

  # Amount, original amount and rate always fit together.
  it "derives the euro amount of a foreign currency" do
    with_expense_fixture do |f|
      input = f.equal("Diner NYC", 1, "2026-08-01", f.ben, f.anna, f.ben)
      input.original_currency, input.original_amount_minor, input.fx_rate = "USD", 10000_i64, 1.0823
      id = f.s.create_expense(f.ben, input)
      e = f.s.get_expense(id)
      e.amount_cents.should eq 9240
      (e.share_of(f.anna) + e.share_of(f.ben)).should eq 9240
      input = e.to_input
      input.amount_cents = 1
      f.s.update_expense(f.ben, id, input)
      f.s.get_expense(id).amount_cents.should eq 9240
    end
  end

  it "rotates the extra euro cent of foreign amounts with the expense ID" do
    with_expense_fixture do |f|
      people = [f.anna, f.ben]
      4.times do
        input = f.equal("Taxi", 0, "2026-09-01", f.anna, f.anna, f.ben)
        # 10,00 USD at 0,999 = 10,01 €, split 5,00 USD : 5,00 USD.
        input.original_currency, input.original_amount_minor, input.fx_rate = "USD", 1000_i64, 0.999
        input.split_mode = Domain::SplitMode::Amount
        input.parts = [Domain::Part.new(f.anna, 500), Domain::Part.new(f.ben, 500)]
        id = f.s.create_expense(f.anna, input)
        e = f.s.get_expense(id)
        e.amount_cents.should eq 1001
        e.share_of(people[id % 2]).should eq 501
      end
    end
  end

  # The weights are amounts in the foreign currency, stored as entered; the
  # euro cents are distributed in proportion to them.
  it "splits foreign currencies by amounts" do
    with_expense_fixture do |f|
      input = f.equal("Hotel", 0, "2026-08-01", f.anna, f.anna, f.ben, f.cleo)
      input.original_currency, input.original_amount_minor, input.fx_rate = "USD", 1000_i64, 1.1
      input.split_mode = Domain::SplitMode::Amount
      input.parts = [Domain::Part.new(f.cleo, 334), Domain::Part.new(f.anna, 333), Domain::Part.new(f.ben, 333)]
      id = f.s.create_expense(f.anna, input)
      e = f.s.get_expense(id)
      e.amount_cents.should eq 909
      (e.share_of(f.anna) + e.share_of(f.ben) + e.share_of(f.cleo)).should eq 909
      e.share_of(f.cleo).should eq 303
      weights(e).should eq [333, 333, 334]

      # The stored input round-trips: saving it unchanged logs nothing.
      acts = f.s.list_activity
      f.s.update_expense(f.anna, id, e.to_input)
      f.s.list_activity.size.should eq acts.size

      # A new rate: same weights, new euro shares.
      input = e.to_input
      input.fx_rate = 1.25
      f.s.update_expense(f.anna, id, input)
      e = f.s.get_expense(id)
      {e.amount_cents, e.share_of(f.cleo), e.parts[2].weight}.should eq({800, 267, 334})

      input.parts = [input.parts[0].copy_with(weight: 433), input.parts[1], input.parts[2].copy_with(weight: 234)]
      f.s.update_expense(f.anna, id, input)
      acts = f.s.list_activity(Store::ActivityFilter.new(expense_id: id, limit: 1))
      acts[0].details.changes.map { |c| "#{c.field}: #{c.old} → #{c.new}" }.join("\n").should contain "Anna 3,46 €"
      # If only the amounts in USD change, not the euro shares, the history
      # lists the amounts in USD.
      Store.weight_summary(Domain::SplitMode::Amount, "USD", [Domain::Share.new(f.anna, 433)], {f.anna => "Anna"})
        .should eq "Anna 4,33 USD"

      # The amounts must add up to the amount in USD.
      input.parts = [input.parts[0].copy_with(weight: 300), input.parts[1], input.parts[2]]
      store_validation_error { f.s.update_expense(f.anna, id, input) }.should contain "10,00 USD"
      # Converted to 0 €.
      input.parts = [input.parts[0].copy_with(weight: 433), input.parts[1], input.parts[2]]
      input.fx_rate = 1e9
      store_validation_error { f.s.update_expense(f.anna, id, input) }.should contain "0 €"
    end
  end

  it "updates an expense and logs the changes" do
    with_expense_fixture do |f|
      id = f.s.create_expense(f.anna, f.equal("Pizza", 3000, "2026-09-01", f.anna, f.anna, f.ben))
      events = [] of Store::ExpenseChange
      f.s.on_expense_change { |c| events << c }

      e = f.s.get_expense(id)
      # Saving unchanged: no log entry, no hook.
      f.s.update_expense(f.ben, id, e.to_input)
      events.should be_empty

      input = e.to_input
      input.title = "Pizza & Wein"
      input.amount_cents = 4500
      input.split_mode = Domain::SplitMode::Shares
      input.parts = [Domain::Part.new(f.anna, 2), Domain::Part.new(f.ben, 1)]
      input.category_id = nil
      f.s.update_expense(f.ben, id, input)
      e = f.s.get_expense(id)
      {e.title, e.amount_cents, e.share_of(f.anna), e.share_of(f.ben), e.category_id, e.category_name}
        .should eq({"Pizza & Wein", 4500, 3000, 1500, nil, nil})
      events.map(&.action).should eq [Store::Action::ExpenseUpdated]

      acts = f.s.list_activity(Store::ActivityFilter.new(expense_id: id))
      acts.size.should eq 2
      {acts[0].action, acts[0].actor_name}.should eq({Store::Action::ExpenseUpdated, "Ben"})
      fields = acts[0].details.changes.to_h { |c| {c.field, c} }
      {fields["Betrag"].old, fields["Betrag"].new}.should eq({"30,00 €", "45,00 €"})
      {fields["Kategorie"].old, fields["Kategorie"].new}.should eq({"Lebensmittel", "–"})
      fields["Aufteilung"].new.should start_with "Nach Anteilen: Anna 30,00 €"
      fields.has_key?("Datum").should be_false

      expect_raises(Store::NotFound) { f.s.update_expense(f.ben, 999_i64, input) }
    end
  end

  # Changes only to rate, rate source or weights (with the same cents) are
  # stored and logged.
  it "updates rate, rate source and weights" do
    with_expense_fixture do |f|
      input = f.equal("Diner", Domain.to_eur_cents(1000, "USD", 1.25), "2026-08-01", f.ben, f.anna, f.ben)
      input.original_currency, input.original_amount_minor, input.fx_rate, input.fx_source = "USD", 1000_i64, 1.25, Domain::FXSource::Ecb
      input.split_mode = Domain::SplitMode::Shares
      input.parts = [Domain::Part.new(f.anna, 1), Domain::Part.new(f.ben, 1)]
      id = f.s.create_expense(f.ben, input)

      input.fx_rate = 1.2501 # same euro cents
      f.s.update_expense(f.anna, id, input)
      f.s.get_expense(id).fx_rate.should eq 1.2501
      c = field_changes(f.s, id)["Kurs"]
      {c.old, c.new}.should eq({"1 € = 1,25 USD (EZB)", "1 € = 1,2501 USD (EZB)"})

      input.fx_source = Domain::FXSource::Manual
      f.s.update_expense(f.anna, id, input)
      f.s.get_expense(id).fx_source.should eq Domain::FXSource::Manual
      field_changes(f.s, id)["Kurs"].new.should eq "1 € = 1,2501 USD (manuell)"

      input.parts = [Domain::Part.new(f.anna, 2), Domain::Part.new(f.ben, 2)]
      f.s.update_expense(f.anna, id, input)
      f.s.get_expense(id).parts[0].weight.should eq 2
      c = field_changes(f.s, id)["Anteile"]
      {c.old, c.new}.should eq({"Anna 1, Ben 1", "Anna 2, Ben 2"})
    end
  end

  it "deletes an expense softly" do
    with_expense_fixture do |f|
      id = f.s.create_expense(f.anna, f.equal("Bahn", 5000, "2026-09-02", f.anna, f.anna, f.ben))
      events = [] of Store::ExpenseChange
      f.s.on_expense_change { |c| events << c }

      f.s.delete_expense(f.ben, id)
      expect_raises(Store::NotFound) { f.s.delete_expense(f.ben, id) }
      e = f.s.get_expense(id)
      e.deleted?.should be_true
      expect_raises(Store::NotFound) { f.s.update_expense(f.ben, id, e.to_input) }
      f.s.list_expenses.should be_empty
      f.s.balances.should be_empty
      events.should eq [Store::ExpenseChange.new(id, Store::Action::ExpenseDeleted)]
      a = f.s.list_activity(Store::ActivityFilter.new(limit: 1))[0]
      {a.action, a.details.title}.should eq({Store::Action::ExpenseDeleted, "Bahn"})
    end
  end

  it "filters expenses" do
    with_expense_fixture do |f|
      a = f.must_create(f.equal("Rewe Einkauf", 1000, "2026-09-01", f.anna, f.anna, f.ben))
      b = f.must_create(f.equal("Kino 100%", 2000, "2026-09-15", f.ben, f.ben, f.cleo))
      input = f.equal("Tanken", 3000, "2026-10-01", f.cleo, f.cleo)
      input.category_id = nil
      input.notes = "Rewe-Tankstelle"
      c = f.must_create(input)

      {
        "all, newest first"          => {Store::ExpenseFilter.new, [c, b, a]},
        "text in title/notes"        => {Store::ExpenseFilter.new(text: "rewe"), [c, a]},
        "LIKE characters"            => {Store::ExpenseFilter.new(text: "100%"), [b]},
        "category"                   => {Store::ExpenseFilter.new(category_id: f.food), [b, a]},
        "without category"           => {Store::ExpenseFilter.new(without_category: true), [c]},
        "person pays or is involved" => {Store::ExpenseFilter.new(participant_id: f.cleo), [c, b]},
        "date range"                 => {Store::ExpenseFilter.new(from: date("2026-09-01"), to: date("2026-09-15")), [b, a]},
        "limit/offset"               => {Store::ExpenseFilter.new(limit: 1, offset: 1), [b]},
        "oldest first"               => {Store::ExpenseFilter.new(sort: Store::ExpenseSort::DateAsc), [a, b, c]},
        "largest first"              => {Store::ExpenseFilter.new(sort: Store::ExpenseSort::AmountDesc), [c, b, a]},
        "smallest first"             => {Store::ExpenseFilter.new(sort: Store::ExpenseSort::AmountAsc), [a, b, c]},
        "amount range"               => {Store::ExpenseFilter.new(min_cents: 1500, max_cents: 2500), [b]},
      }.each do |name, (filter, want)|
        es = f.s.list_expenses(filter)
        {name, ids(es)}.should eq({name, want})
        es.each { |e| e.shares.should_not be_empty }
      end
    end
  end

  it "rotates the extra cent with the expense ID, also after an update" do
    with_expense_fixture do |f|
      people = [f.anna, f.ben]
      extra = Hash(Int64, Int32).new(0)
      4.times do
        id = f.s.create_expense(f.anna, f.equal("Kaffee", 301, "2026-09-01", f.anna, f.ben, f.anna))
        e = f.s.get_expense(id)
        want = people[id % 2]
        e.share_of(want).should eq 151
        extra[want] += 1

        input = e.to_input
        input.amount_cents = 501
        f.s.update_expense(f.anna, id, input)
        f.s.get_expense(id).share_of(want).should eq 251
      end
      extra.should eq({f.anna => 2, f.ben => 2})
    end
  end

  it "predicts the next expense ID" do
    with_expense_fixture do |f|
      f.s.next_expense_id.should eq 1
      id = f.must_create(f.equal("Kaffee", 300, "2026-09-01", f.anna, f.anna))
      f.s.delete_expense(f.anna, id)
      f.s.next_expense_id.should eq id + 1
      f.must_create(f.equal("Tee", 300, "2026-09-01", f.anna, f.anna)).should eq id + 1
    end
  end

  it "searches text ignoring the case of umlauts" do
    with_expense_fixture do |f|
      mk = ->(title : String, notes : String) do
        input = f.equal(title, 1000, "2026-09-01", f.anna, f.anna, f.ben)
        input.notes = notes
        f.s.create_expense(f.anna, input)
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
        {text, ids(f.s.list_expenses(Store::ExpenseFilter.new(text: text)))}.should eq({text, want})
      end
    end
  end

  it "computes balances with a reimbursement" do
    with_expense_fixture do |f|
      f.s.create_expense(f.anna, f.equal("Essen", 3000, "2026-09-01", f.anna, f.anna, f.ben, f.cleo))
      # Ben pays Anna back 10 €.
      r = Store::ExpenseInput.new(title: "Rückzahlung", date: date("2026-09-02"), paid_by: f.ben, reimbursement: true,
        amount_cents: 1000, parts: [Domain::Part.new(f.anna)])
      e = f.s.get_expense(f.s.create_expense(f.ben, r))
      {e.reimbursement?, e.split_mode, e.share_of(f.anna)}.should eq({true, Domain::SplitMode::Equal, 1000})
      b = f.s.balances
      {b[f.anna], b[f.ben], b[f.cleo]}.should eq({1000, 0, -1000})
    end
  end

  it "rejects a second instance of a recurrence on the same date" do
    with_expense_fixture do |f|
      rid = insert_recurring(f.s, "{}", "2026-01-31", "2026-02-28")
      input = f.equal("Miete", 100000, "2026-01-31", f.anna, f.anna, f.ben)
      input.recurring_id = rid
      before = f.s.list_activity.size
      f.s.create_expense(nil, input)
      expect_raises(Store::RecurringExists) { f.s.create_expense(nil, input) }
      acts = f.s.list_activity
      acts.size.should eq before + 1
      {acts[0].actor_id, acts[0].actor_name}.should eq({nil, nil})
    end
  end

  it "rejects an instance of a paused or deleted recurrence" do
    with_expense_fixture do |f|
      rid = insert_recurring(f.s, "{}", "2026-01-31", "2026-02-28")
      f.s.db.exec("UPDATE recurring SET active = 0 WHERE id = ?", rid)
      input = f.equal("Miete", 100000, "2026-01-31", f.anna, f.anna, f.ben)
      input.recurring_id = rid
      expect_raises(Store::RecurringChanged) { f.s.create_expense(nil, input) }
      input.recurring_id = 999
      expect_raises(Store::RecurringChanged) { f.s.create_expense(nil, input) }
    end
  end

  # An input error, not a 500.
  it "rejects moving an instance onto the date of another instance" do
    with_expense_fixture do |f|
      rid = insert_recurring(f.s, "{}", "2026-01-31", "2026-03-31")
      input = f.equal("Miete", 100000, "2026-01-31", f.anna, f.anna, f.ben)
      input.recurring_id = rid
      f.s.create_expense(nil, input)
      input.date = date("2026-02-28")
      second = f.s.create_expense(nil, input)
      input.date = date("2026-01-31")
      store_validation_error { f.s.update_expense(f.anna, second, input) }.should contain "Termin"
    end
  end

  it "writes and rotates backups" do
    with_expense_fixture do |f|
      with_temp_dir do |dir|
        # Unrelated files are left untouched.
        File.write(File.join(dir, "notiz.txt"), "x")
        base = Time.utc(2026, 10, 1, 3, 0, 0)
        paths = (0...9).map do |i|
          f.s.clock = -> { base.shift(days: i) }
          f.s.backup(dir, 7)
        end
        Dir.children(dir).size.should eq 8
        File.exists?(paths[0]).should be_false
        b = Store.open(paths[8])
        b.list_participants.size.should eq 3
        b.close
      end
    end
  end

  it "writes backups readable by the owner only" do
    with_expense_fixture do |f|
      with_temp_dir do |dir|
        File.info(f.s.backup(dir, 7)).permissions.should eq File::Permissions.new(0o600)
      end
    end
  end

  it "logs a failing expense-change hook and keeps the change" do
    with_expense_fixture do |f|
      f.s.on_expense_change { |_| raise "hook broke" }
      id = f.must_create(f.equal("Kino", 1000, "2026-09-01", f.anna, f.anna))
      f.s.get_expense(id).title.should eq "Kino"
      SPEC_LOG.to_s.should contain %(level=ERROR msg="expense change hook failed" expense_id=#{id} err="hook broke")
    end
  end

  it "rotates only regular backup files" do
    with_temp_dir do |dir|
      other = File.join(dir, "elsewhere.db")
      File.write(other, "x")
      link = File.join(dir, "zipfelkasse-20000101-000000.db")
      File.symlink(other, link)
      %w(20260101 20260102).each { |d| File.write(File.join(dir, "zipfelkasse-#{d}-000000.db"), "x") }
      Store.rotate_backups(dir, 1)
      Dir.children(dir).sort.should eq ["elsewhere.db", "zipfelkasse-20000101-000000.db", "zipfelkasse-20260102-000000.db"]
    end
  end

  it "parses stored dates strictly" do
    Store.parse_date("2026-09-01").should eq Time.utc(2026, 9, 1)
    ["2026-9-1", "2026-09-01x", "2026-09-01T00:00:00Z", " 2026-09-01", "2026-02-30"].each do |s|
      expect_raises(Exception) { Store.parse_date(s) }
    end
  end

  it "rolls back a transaction left early and stays usable" do
    with_store do |s|
      leave_transaction_early(s)
      s.get_setting(Store::SETTING_GROUP_NAME).should eq "Zipfelkasse"
      s.set_group_name(nil, "WG")
      s.group_name.should eq "WG"
    end
  end

  it "survives concurrent writes to a file database" do
    with_temp_dir do |dir|
      s = Store.open(File.join(dir, "t.db"))
      anna = must_participant(s, "Anna")
      errors = [] of Exception
      WaitGroup.wait do |wg|
        20.times do |i|
          wg.spawn do
            input = Store::ExpenseInput.new(title: "x", date: date("2026-09-01"), paid_by: anna,
              amount_cents: 100_i64 + i, parts: [Domain::Part.new(anna)])
            s.create_expense(anna, input)
          rescue ex
            errors << ex
          end
        end
      end
      errors.should be_empty
      s.list_expenses.size.should eq 20
      s.close
    end
  end
end
