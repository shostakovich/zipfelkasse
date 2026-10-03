require "../spec_helper"

private def leave_transaction_early(store : Store) : Nil
  store.transaction do |tx|
    tx.exec("UPDATE settings SET value = 'Weg' WHERE key = ?", Store::SETTING_GROUP_NAME)
    return
  end
end

describe Store do
  use_store

  it "migrates and seeds a new database" do
    store.schema_version.should eq Store::LATEST_VERSION
    store.list_activity.should be_empty
    cats = store.list_categories
    cats.size.should eq 10
    cats.first.name.should eq "Lebensmittel"
    cats.last.name.should eq "Sonstiges"
    store.group_name.should eq "Zipfelkasse"
  end

  it "rejects schema versions it cannot handle" do
    [3, Store::LATEST_VERSION + 1].each do |version|
      store.db.exec("PRAGMA user_version = #{version}")
      expect_raises(Store::Error, /schema version #{version}/) { store.migrate }
    end
  end

  it "applies migrations above the current version once" do
    next_version = Store::LATEST_VERSION + 1
    migrations = Store::MIGRATIONS + [{next_version, "ALTER TABLE settings ADD COLUMN note TEXT"},
                                      {next_version + 1, "UPDATE settings SET value = 'Neu'"}]
    2.times do
      store.migrate(migrations)
      store.schema_version.should eq next_version + 1
    end
    store.group_name.should eq "Neu"
  end

  it "removes the legacy fields of recurring templates in migration 6" do
    legacy = %q({"title":"Miete","date":"2026-01-01T00:00:00Z","category_id":0,"paid_by":1,"fx_rate":1,) +
             %q("fx_source":"","recurring_id":0,"parts":[{"participant_id":1,"weight":1}]})
    store.db.exec("INSERT INTO recurring (template_json, frequency, start_date, next_date, created_at, updated_at) " \
                  "VALUES (?, 'monthly', '2026-01-01', '2026-02-01', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')", legacy)
    store.db.exec("PRAGMA user_version = 5")

    store.migrate(Store::MIGRATIONS.select { |version, _| version == 6 })
    JSON.parse(store.db.scalar("SELECT template_json FROM recurring").as(String)).as_h.keys
      .should eq %w(title paid_by fx_rate parts)
    store.list_recurring.first.template.category_id.should be_nil
  end

  it "opens a file database twice" do
    with_temp_dir do |dir|
      path = File.join(dir, "sub", "zipfelkasse.db")
      s = Store.open(path)
      s.create_participant(nil, "Anna")
      s.db.scalar("PRAGMA journal_mode").should eq "wal"
      s.db.scalar("PRAGMA foreign_keys").should eq 1
      s.close

      s = Store.open(path)
      s.list_participants.size.should eq 1
      s.close
    end
  end

  it "collapses whitespace in the group name and rejects an empty one" do
    store.set_group_name(nil, "  WG   Kastanienallee ")
    store.group_name.should eq "WG Kastanienallee"
    expect_invalid("Bitte einen Namen für die Gruppe angeben.") { store.set_group_name(nil, "   ") }
  end

  it "parses stored dates strictly" do
    Store.parse_date("2026-09-01").should eq Time.utc(2026, 9, 1)
    ["2026-9-1", "2026-09-01x", "2026-09-01T00:00:00Z", " 2026-09-01", "2026-02-30"].each do |s|
      expect_raises(Exception) { Store.parse_date(s) }
    end
  end

  it "rolls back a transaction left early and stays usable" do
    leave_transaction_early(store)
    store.group_name.should eq "Zipfelkasse"
    store.set_group_name(nil, "WG")
    store.group_name.should eq "WG"
  end

  it "survives concurrent writes to a file database" do
    with_temp_dir do |dir|
      s = Store.open(File.join(dir, "t.db"))
      anna = s.create_participant(nil, "Anna")
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
