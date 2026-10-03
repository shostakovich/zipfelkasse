require "file_utils"
require "../store/expense_fixture"

private alias Store = Zipfelkasse::Store
private alias MCP = Zipfelkasse::MCP

private def with_temp_dir(&)
  dir = File.tempname("zipfelkasse-sandbox")
  Dir.mkdir(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

# A store with a real file (the sandbox attaches the file, which :memory:
# cannot do), plus a YNAB token and status that must stay hidden.
private def with_file_fixture(&)
  with_temp_dir do |dir|
    f = ExpenseFixture.new(Store.open(File.join(dir, "zipfelkasse.db")))
    begin
      f.s.db.exec("INSERT INTO ynab_config (participant_id, token, updated_at) VALUES (?, 'SECRET-TOKEN', '2026-01-01T00:00:00Z')", f.anna)
      f.s.set_ynab_status(f.anna, Store::YNABStatus.new(error: "SECRET-STATUS", last_run: Time.utc))
      yield f, dir
    ensure
      f.s.close
    end
  end
end

private def sandbox(f : ExpenseFixture) : MCP::SQLSandbox
  MCP::SQLSandbox.new(f.s.path)
end

private def validation_error?(&) : Bool
  yield
  false
rescue Zipfelkasse::Domain::ValidationError
  true
end

describe Zipfelkasse::MCP::SQLSandbox do
  it "checks that a query is a single SELECT" do
    {
      "SELECT 1"                                                  => "SELECT 1",
      "  select 1 ;  "                                            => "  select 1 ",
      "-- comment\nWITH x AS (SELECT 1) SELECT * FROM x;; -- end" => "-- comment\nWITH x AS (SELECT 1) SELECT * FROM x",
      "/* a; b */ SELECT ';' AS x"                                => "/* a; b */ SELECT ';' AS x",
      %(SELECT "a;b", [c;d], `e;f`)                               => %(SELECT "a;b", [c;d], `e;f`),
      "SELECT 'it''s; fine'"                                      => "SELECT 'it''s; fine'",
    }.each do |input, want|
      MCP::SQLSandbox.check_select(input).should eq(want)
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
      fail "accepted #{input.inspect}" unless validation_error? { MCP::SQLSandbox.check_select(input) }
    end
  end

  it "runs read-only queries" do
    with_file_fixture do |f|
      f.must_create(f.equal("Rewe", 3000, "2026-09-01", f.anna, f.anna, f.ben, f.cleo))
      f.must_create(f.equal("Kino", 2000, "2026-09-02", f.ben, f.anna, f.ben))

      res = sandbox(f).query(<<-SQL)
        SELECT e.title AS title, e.amount_cents, e.fx_rate, NULL AS empty, x'00ff' AS b
        FROM expenses e WHERE e.deleted_at IS NULL ORDER BY e.date DESC;
        SQL
      res.columns.should eq(%w(title amount_cents fx_rate empty b))
      res.rows.should eq([["Kino", 2000_i64, 1.0, nil, "[BLOB, 2 Bytes]"], ["Rewe", 3000_i64, 1.0, nil, "[BLOB, 2 Bytes]"]])
      res.truncated?.should be_false

      # Empty result, WITH, row limit, order.
      res = sandbox(f).query("SELECT * FROM participants WHERE name = 'Nobody'")
      res.rows.should be_empty
      res.columns.size.should eq(4)
      res = sandbox(f).query("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n LIMIT 1000) SELECT i FROM n ORDER BY i DESC")
      res.rows.size.should eq(MCP::SQLSandbox::MAX_ROWS)
      res.truncated?.should be_true
      res.rows[0][0].should eq(1000_i64)
      res.rows[MCP::SQLSandbox::MAX_ROWS - 1][0].should eq(1000_i64 - MCP::SQLSandbox::MAX_ROWS + 1)

      # Long texts are truncated.
      res = sandbox(f).query("SELECT length(x), x FROM (SELECT printf('%.5000c', 'a') AS x)")
      res.rows[0][0].should eq(5000_i64)
      res.rows[0][1].as(String).size.should eq(MCP::SQLSandbox::MAX_CELL_RUNES)

      # SQL errors are ValidationErrors with the SQLite message.
      store_validation_error { sandbox(f).query("SELECT x FROM doesnotexist") }
        .should eq("SQL error: no such table: doesnotexist (1)")
    end
  end

  it "keeps SQLite's number formats apart" do
    with_file_fixture do |f|
      res = sandbox(f).query("SELECT 1.0, 0.1 + 0.2, 1e30, -5, 9e999, -9e999, '<&>', json_object('a', 1)")
      res.rows.should eq([[1.0, 0.30000000000000004, 1e30, -5_i64, Float64::INFINITY, -Float64::INFINITY,
                           "<&>", %({"a":1})]])
      res = sandbox(f).query("SELECT 1, 1, 'a' AS x, 'b' AS x")
      res.columns.should eq(%w(1 1 x x))
    end
  end

  it "has the fold function in the sandbox" do
    with_file_fixture do |f|
      res = sandbox(f).query("SELECT #{Store::FOLD_FUNC}('BÄCKER Straße'), #{Store::FOLD_FUNC}(NULL), #{Store::FOLD_FUNC}(42)")
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
        fail "no error for #{q}" unless validation_error? { sandbox(f).query(q) }
      end
      # Nothing in the sandbox contains the token, not via the schema or settings either.
      [
        "SELECT * FROM settings",
        "SELECT name, sql FROM sqlite_schema",
        "SELECT * FROM pragma_database_list",
        "SELECT * FROM pragma_table_list",
      ].each do |q|
        rows = sandbox(f).query(q).rows.to_s
        fail "#{q} reveals YNAB: #{rows}" if rows.includes?("SECRET") || rows.downcase.includes?("ynab")
      end
      sandbox(f).query("SELECT key FROM settings ORDER BY key").rows.should eq([["group_name"]])

      # The schema via MCP shows no YNAB tables.
      objects = f.s.schema
      objects.each do |o|
        fail "schema contains #{o.name}" if o.name.includes?("ynab") || o.sql.includes?("ynab")
      end
      objects.count(&.type.==("table")).should eq(Store::EXPOSED_TABLES.size)
    end
  end

  it "protects the database below the lexical check" do
    with_file_fixture do |f, dir|
      f.must_create(f.equal("Rewe", 3000, "2026-09-01", f.anna, f.anna, f.ben))
      path = f.s.path
      before = File.read(path)
      other = File.join(dir, "copy.db")

      sandbox(f).with_sandbox(Time.instant + 5.seconds) do |conn|
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
          expect_raises(Exception) { MCP::SQLSandbox.run_wrapped(conn, body) }
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
        sandbox(f).query("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n) SELECT i FROM n WHERE i < 0", 300.milliseconds)
      end
      msg.should contain("aborted")
      (Time.instant - start).should be < 3.seconds
    end
  end

  it "needs a database file for queries" do
    store_validation_error { MCP::SQLSandbox.new(":memory:").query("SELECT 1") }.should contain(":memory:")
  end
end
