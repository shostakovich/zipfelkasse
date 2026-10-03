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

  it "applies migrations above the base version once" do
    migrations = [{6, "ALTER TABLE settings ADD COLUMN note TEXT"}, {7, "UPDATE settings SET value = 'Neu'"}]
    2.times do
      store.migrate(migrations)
      store.schema_version.should eq 7
    end
    store.group_name.should eq "Neu"
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
