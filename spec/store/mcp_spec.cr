require "file_utils"
require "./expense_fixture"

private alias Store = Zipfelkasse::Store
private alias StatsFilter = Zipfelkasse::Store::StatsFilter
private alias StatRow = Zipfelkasse::Store::StatRow

private def with_temp_dir(&)
  dir = File.tempname("zipfelkasse-mcp")
  Dir.mkdir(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

# A store with a real file (the sandbox attaches the file read-only, which
# :memory: cannot do), plus a YNAB token and status that must stay hidden.
private def with_file_fixture(&)
  with_temp_dir do |dir|
    f = ExpenseFixture.new(Store.open(File.join(dir, "zipfelkasse.db")))
    begin
      f.s.db.exec("INSERT INTO ynab_config (participant_id, token, updated_at) VALUES (?, 'SECRET-TOKEN', '2026-01-01T00:00:00Z')", f.anna)
      f.s.set_ynab_status(f.anna, Store::YNABStatus.new(error: "SECRET-STATUS", last_run: Time.utc))
      f.s.set_setting("ynab.token_backup", "SECRET-TOKEN")
      yield f, dir
    ensure
      f.s.close
    end
  end
end

private def validation_error?(&) : Bool
  yield
  false
rescue Zipfelkasse::Domain::ValidationError
  true
end

private def stat_string(rows : Array(StatRow)) : String
  rows.join { |r| "#{r.category}#{r.title}|#{r.period}|#{r.person}|#{r.count}|#{r.amount_cents}|#{r.paid_cents};" }
end

describe "Store MCP queries" do
  it "checks that a query is a single SELECT" do
    {
      "SELECT 1"                                                  => "SELECT 1",
      "  select 1 ;  "                                            => "  select 1 ",
      "-- comment\nWITH x AS (SELECT 1) SELECT * FROM x;; -- end" => "-- comment\nWITH x AS (SELECT 1) SELECT * FROM x",
      "/* a; b */ SELECT ';' AS x"                                => "/* a; b */ SELECT ';' AS x",
      %(SELECT "a;b", [c;d], `e;f`)                               => %(SELECT "a;b", [c;d], `e;f`),
      "SELECT 'it''s; fine'"                                      => "SELECT 'it''s; fine'",
    }.each do |input, want|
      Store.check_select(input).should eq(want)
    end
    [
      "", "   ", "-- only a comment",
      "DELETE FROM expenses",
      "PRAGMA query_only = OFF",
      "ATTACH 'x.db' AS x",
      "VACUUM INTO '/tmp/x.db'",
      "SELECT 1; DELETE FROM expenses",
      "SELECT 1; ATTACH DATABASE 'file:x' AS y",
      "SELECT 'a'; PRAGMA query_only=0",
      "SELECT 1 /* ; */; SELECT 2",
      "SELECT 1\0; DROP TABLE expenses",
      "(SELECT 1)",
      "EXPLAIN SELECT 1",
    ].each do |input|
      fail "accepted #{input.inspect}" unless validation_error? { Store.check_select(input) }
    end
  end

  it "runs read-only queries" do
    with_file_fixture do |f|
      f.must_create(f.equal("Rewe", 3000, "2026-09-01", f.anna, f.anna, f.ben, f.cleo))
      f.must_create(f.equal("Kino", 2000, "2026-09-02", f.ben, f.anna, f.ben))

      res = f.s.read_only_query(<<-SQL)
        SELECT e.title AS title, e.amount_cents, e.fx_rate, NULL AS empty, x'00ff' AS b
        FROM expenses e WHERE e.deleted_at IS NULL ORDER BY e.date DESC;
        SQL
      res.columns.should eq(%w(title amount_cents fx_rate empty b))
      res.rows.should eq([["Kino", 2000_i64, 1.0, nil, "[BLOB, 2 Bytes]"], ["Rewe", 3000_i64, 1.0, nil, "[BLOB, 2 Bytes]"]])
      res.truncated?.should be_false

      # Empty result, WITH, row limit, order.
      res = f.s.read_only_query("SELECT * FROM participants WHERE name = 'Nobody'")
      res.rows.should be_empty
      res.columns.size.should eq(4)
      res = f.s.read_only_query("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n LIMIT 1000) SELECT i FROM n ORDER BY i DESC")
      res.rows.size.should eq(Store::SQL_MAX_ROWS)
      res.truncated?.should be_true
      res.rows[0][0].should eq(1000_i64)
      res.rows[Store::SQL_MAX_ROWS - 1][0].should eq(1000_i64 - Store::SQL_MAX_ROWS + 1)

      # Long texts are truncated.
      res = f.s.read_only_query("SELECT length(x), x FROM (SELECT printf('%.5000c', 'a') AS x)")
      res.rows[0][0].should eq(5000_i64)
      res.rows[0][1].as(String).size.should eq(Store::SQL_MAX_CELL_RUNES)

      # SQL errors are ValidationErrors with the SQLite message.
      store_validation_error { f.s.read_only_query("SELECT x FROM doesnotexist") }
        .should eq("SQL error: no such table: doesnotexist (1)")
    end
  end

  it "keeps SQLite's number formats apart" do
    with_file_fixture do |f|
      res = f.s.read_only_query("SELECT 1.0, 0.1 + 0.2, 1e30, -5, 9e999, -9e999, '<&>', json_object('a', 1)")
      res.rows.should eq([[1.0, 0.30000000000000004, 1e30, -5_i64, Float64::INFINITY, -Float64::INFINITY,
                           "<&>", %({"a":1})]])
      res = f.s.read_only_query("SELECT 1, 1, 'a' AS x, 'b' AS x")
      res.columns.should eq(%w(1 1 x x))
    end
  end

  it "has the fold function in the sandbox" do
    with_file_fixture do |f|
      res = f.s.read_only_query("SELECT #{Store::FOLD_FUNC}('BÄCKER Straße'), #{Store::FOLD_FUNC}(NULL), #{Store::FOLD_FUNC}(42)")
      res.rows[0].should eq(["bäcker strasse", nil, 42_i64])
    end
  end

  it "hides the YNAB tables and settings" do
    with_file_fixture do |f|
      [
        "SELECT token FROM ynab_config",
        "SELECT * FROM main.ynab_config",
        %(SELECT * FROM "YNAB_CONFIG"),
        "SELECT * FROM ynab_sync",
        "SELECT * FROM src.ynab_config",
        "SELECT * FROM temp.ynab_config",
      ].each do |q|
        fail "no error for #{q}" unless validation_error? { f.s.read_only_query(q) }
      end
      # Nothing in the sandbox contains the token, not via the schema or settings either.
      [
        "SELECT * FROM settings",
        "SELECT name, sql FROM sqlite_schema",
        "SELECT * FROM pragma_database_list",
        "SELECT * FROM pragma_table_list",
      ].each do |q|
        rows = f.s.read_only_query(q).rows.to_s
        fail "#{q} reveals YNAB: #{rows}" if rows.includes?("SECRET") || rows.downcase.includes?("ynab")
      end
      f.s.read_only_query("SELECT key FROM settings ORDER BY key").rows.should eq([["default_currency"], ["group_name"]])

      # The schema via MCP shows no YNAB tables.
      objects = f.s.mcp_schema
      objects.each do |o|
        fail "mcp_schema contains #{o.name}" if o.name.includes?("ynab") || o.sql.includes?("ynab")
      end
      objects.count(&.type.==("table")).should eq(Store::MCP_TABLES.size)
    end
  end

  it "protects the database below the lexical check" do
    with_file_fixture do |f, dir|
      f.must_create(f.equal("Rewe", 3000, "2026-09-01", f.anna, f.anna, f.ben))
      path = f.s.path
      before = File.read(path)
      other = File.join(dir, "copy.db")

      f.s.with_sandbox(Time.instant + 5.seconds) do |conn|
        [
          "INSERT INTO participants (name, created_at) VALUES ('X', 'x')",
          "UPDATE expenses SET amount_cents = 1",
          "DELETE FROM expenses",
          "CREATE TABLE t (x)",
          "CREATE TEMP TABLE t (x)",
          "ATTACH DATABASE '#{path}' AS real",
          "ATTACH DATABASE 'file:#{path}?mode=ro' AS real",
          "VACUUM INTO '#{other}'",
        ].each do |q|
          expect_raises(SQLite3::Exception) { conn.exec(q) }
        end
        File.exists?(other).should be_false

        # Even with query_only off, the file is out of reach.
        conn.exec("PRAGMA query_only = OFF")
        expect_raises(SQLite3::Exception) { conn.exec("ATTACH DATABASE '#{path}' AS real") }
        conn.exec("DELETE FROM expenses")

        # Embedded in run_wrapped, only SELECTs are syntactically possible.
        ["DELETE FROM expenses", "PRAGMA query_only = OFF", "SELECT 1) SELECT 1; ATTACH 'x' AS y; SELECT (1"].each do |body|
          expect_raises(Exception) { Store.run_wrapped(conn, body) }
        end
      end

      File.read(path).should eq(before)
      f.s.list_expenses.size.should eq(1)
    end
  end

  it "aborts slow queries" do
    with_file_fixture do |f|
      start = Time.instant
      msg = store_validation_error do
        f.s.read_only_query("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n) SELECT i FROM n WHERE i < 0", 300.milliseconds)
      end
      msg.should contain("aborted")
      (Time.instant - start).should be < 3.seconds
    end
  end

  it "needs a database file for queries" do
    with_store do |s|
      store_validation_error { s.read_only_query("SELECT 1") }.should contain(":memory:")
    end
  end

  it "summarizes the data" do
    with_expense_fixture do |f|
      o = f.s.mcp_overview
      {o.expenses, o.reimbursements, o.first_date, o.last_date}.should eq({0, 0, nil, nil})
      f.must_create(f.equal("Rewe", 3000, "2026-08-15", f.anna, f.anna, f.ben))
      input = f.equal("Lidl", 500, "2026-09-11", f.anna, f.anna)
      input.category_id = 0_i64
      f.must_create(input)
      f.must_create(Store::ExpenseInput.new(title: "Ausgleich", date: date("2026-09-13"), paid_by: f.ben, amount_cents: 777,
        reimbursement: true, parts: [Zipfelkasse::Domain::Part.new(f.anna)]))
      o = f.s.mcp_overview
      {o.expenses, o.reimbursements, o.without_category}.should eq({2, 1, 1})
      {o.first_date, o.last_date}.should eq({date("2026-08-15"), date("2026-09-13")})
      o.activity_actions.should eq(%w(expense_created settings_updated))
    end
  end

  it "sums up statistics" do
    with_expense_fixture do |f|
      rest = f.s.list_categories[1].id
      f.must_create(f.equal("Rewe", 3000, "2026-08-15", f.anna, f.anna, f.ben, f.cleo))
      f.must_create(f.equal("Edeka", 1000, "2026-09-01", f.ben, f.anna, f.ben))
      input = f.equal("Pizza", 4000, "2026-09-10", f.cleo, f.ben, f.cleo)
      input.category_id = rest
      f.must_create(input)
      input = f.equal("Uncategorized", 500, "2026-09-11", f.anna, f.anna)
      input.category_id = 0_i64
      f.must_create(input)
      deleted = f.must_create(f.equal("Deleted", 9999, "2026-09-12", f.anna, f.anna))
      f.s.delete_expense(f.anna, deleted)
      f.must_create(Store::ExpenseInput.new(title: "Reimbursement", date: date("2026-09-13"), paid_by: f.ben,
        amount_cents: 777, reimbursement: true, parts: [Zipfelkasse::Domain::Part.new(f.anna)]))

      [
        {StatsFilter.new(group_by: Store::STATS_BY_CATEGORY), "Lebensmittel|||2|4000|0;Restaurant|||1|4000|0;No category|||1|500|0;"},
        {StatsFilter.new(group_by: Store::STATS_BY_MONTH), "|2026-08||1|3000|0;|2026-09||3|5500|0;"},
        {StatsFilter.new(group_by: Store::STATS_BY_CATEGORY_MONTH, from: date("2026-09-01")), "Restaurant|2026-09||1|4000|0;Lebensmittel|2026-09||1|1000|0;No category|2026-09||1|500|0;"},
        {StatsFilter.new(group_by: Store::STATS_BY_CATEGORY, participant_id: f.ben), "Restaurant|||1|2000|0;Lebensmittel|||2|1500|0;"},
        {StatsFilter.new(group_by: Store::STATS_BY_MONTH, participant_id: f.anna, to: date("2026-08-31")), "|2026-08||1|1000|0;"},
        {StatsFilter.new(group_by: Store::STATS_BY_PERSON), "||Ben|3|3500|1000;||Cleo|2|3000|4000;||Anna|3|2000|3500;"},
        {StatsFilter.new(group_by: Store::STATS_BY_PERSON, from: date("2026-09-01"), participant_id: f.anna), "||Anna|2|1000|500;"},
        {StatsFilter.new(group_by: Store::STATS_BY_CATEGORY, without_category: true), "No category|||1|500|0;"},
        {StatsFilter.new(group_by: Store::STATS_BY_MONTH, category_id: f.food), "|2026-08||1|3000|0;|2026-09||1|1000|0;"},
        {StatsFilter.new(group_by: Store::STATS_BY_PERSON, category_id: rest), "||Ben|1|2000|0;||Cleo|1|2000|4000;"},
        {StatsFilter.new(group_by: Store::STATS_BY_PERSON, without_category: true), "||Anna|1|500|500;"},
        {StatsFilter.new(group_by: Store::STATS_BY_YEAR), "|2026||4|8500|0;"},
        {StatsFilter.new(group_by: Store::STATS_BY_WEEK), "|2026-W33||1|3000|0;|2026-W36||1|1000|0;|2026-W37||2|4500|0;"},
        {StatsFilter.new(group_by: Store::STATS_BY_TITLE, any_text: ["pizza", "REWE"]), "Pizza|||1|4000|0;Rewe|||1|3000|0;"},
        {StatsFilter.new(group_by: Store::STATS_BY_MONTH, any_text: ["edeka"]), "|2026-09||1|1000|0;"},
      ].each do |filter, want|
        stat_string(f.s.stats(filter)).should eq(want), failure_message: "#{filter}: got #{stat_string(f.s.stats(filter))}"
      end
      store_validation_error { f.s.stats(StatsFilter.new(group_by: "nonsense")) }.should eq(%(Unknown grouping "nonsense".))
    end
  end

  it "groups titles regardless of case" do
    with_expense_fixture do |f|
      f.must_create(f.equal("Rewe", 3000, "2026-08-15", f.anna, f.anna))
      f.must_create(f.equal("REWE", 1000, "2026-08-16", f.anna, f.anna))
      f.must_create(f.equal("Lidl", 500, "2026-08-17", f.anna, f.anna))
      rows = f.s.stats(StatsFilter.new(group_by: Store::STATS_BY_TITLE))
      rows.size.should eq(2)
      rows[0].title.should eq("Rewe") # binary max: "Rewe" > "REWE"
      {rows[0].count, rows[0].amount_cents}.should eq({2, 4000})
    end
  end

  it "fills empty periods" do
    periods = ->(rows : Array(StatRow)) { rows.join(",") { |r| "#{r.period}=#{r.amount_cents}" } }
    rows = [StatRow.new(period: "2026-01", amount_cents: 1), StatRow.new(period: "2026-04", amount_cents: 4)]
    periods.call(Store.fill_periods(rows, Store::STATS_BY_MONTH, date("2025-12-20"), date("2026-04-02")))
      .should eq("2025-12=0,2026-01=1,2026-02=0,2026-03=0,2026-04=4")
    rows = [StatRow.new(period: "2025-W52", amount_cents: 1)]
    periods.call(Store.fill_periods(rows, Store::STATS_BY_WEEK, date("2025-12-24"), date("2026-01-07")))
      .should eq("2025-W52=1,2026-W01=0,2026-W02=0")
    periods.call(Store.fill_periods(Array(StatRow).new, Store::STATS_BY_YEAR, date("2024-06-01"), date("2026-01-01")))
      .should eq("2024=0,2025=0,2026=0")
    Store.fill_periods(rows, Store::STATS_BY_CATEGORY, date("2024-06-01"), date("2026-01-01")).size.should eq(1)
    # Rows outside the range stay, in period order.
    rows = [StatRow.new(period: "2025-01", amount_cents: 1), StatRow.new(period: "2026-05", amount_cents: 5)]
    periods.call(Store.fill_periods(rows, Store::STATS_BY_MONTH, date("2026-02-10"), date("2026-03-01")))
      .should eq("2025-01=1,2026-02=0,2026-03=0,2026-05=5")
    Store.fill_periods(rows, Store::STATS_BY_MONTH, date("2026-03-01"), date("2026-02-01")).should eq(rows)
  end

  it "computes periods" do
    [
      {Store::STATS_BY_YEAR, "2026", "2026-01-01"},
      {Store::STATS_BY_MONTH, "2026-09", "2026-09-01"},
      {Store::STATS_BY_WEEK, "2026-W01", "2025-12-29"},
      {Store::STATS_BY_WEEK, "2026-W40", "2026-09-28"},
      {Store::STATS_BY_WEEK, "2020-W53", "2020-12-28"},
    ].each do |group_by, period, start|
      got = Store.period_start(group_by, period).not_nil!
      Store.format_date(got).should eq(start)
      Store.period_of(group_by, got).should eq(period)
    end
    Store.period_start(Store::STATS_BY_MONTH, "nonsense").should be_nil

    Store.periods(Store::STATS_BY_WEEK, date("2026-09-30"), date("2026-10-12")).should eq(%w(2026-W40 2026-W41 2026-W42))
    Store.periods(Store::STATS_BY_YEAR, date("2026-09-30"), date("2026-09-29")).should be_empty
    Store.period_end(Store::STATS_BY_MONTH, date("2024-02-10")).should eq(date("2024-02-29"))
    Store.period_end(Store::STATS_BY_WEEK, date("2026-10-03")).should eq(date("2026-10-04"))
    Store.period_end(Store::STATS_BY_YEAR, date("2026-10-03")).should eq(date("2026-12-31"))
    Store.time_grouping?(Store::STATS_BY_WEEK).should be_true
    Store.time_grouping?(Store::STATS_BY_CATEGORY_MONTH).should be_false

    {"2024-02-29" => "2023-02-28", "2024-03-31" => "2023-03-31", "2023-02-28" => "2022-02-28"}.each do |input, want|
      Store.format_date(Store.shift_date_year(date(input), -1)).should eq(want)
    end
    Store.format_date(Store.shift_date_year(date("2023-02-28"), 1)).should eq("2024-02-28")

    {"2025-09" => "2026-09", "2025-W40" => "2026-W40", "2025" => "2026", "" => "",
     "2020-W53" => "2021-W52", "2025-W53" => "2026-W53"}.each do |input, want|
      Store.shift_period_year(input, 1).should eq(want)
    end
  end
end
