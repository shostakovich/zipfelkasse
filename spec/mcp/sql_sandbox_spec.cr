require "../spec_helper"

describe MCP::SQLSandbox do
  describe "#query" do
    around_each do |example|
      with_temp_dir do |dir|
        Household.within(Store.open(File.join(dir, "zipfelkasse.db"))) { example.run }
      end
    end

    {
      "  select 1 AS x ;  "                       => [[1_i64]],
      "SELECT 1 AS x;;"                           => [[1_i64]],
      "SELECT 1 AS x -- end"                      => [[1_i64]],
      "/* a; b */ SELECT ';' AS x"                => [[";"]],
      "WITH y AS (SELECT 2 AS x) SELECT * FROM y" => [[2_i64]],
    }.each do |query, rows|
      it "runs #{query.inspect}" do
        MCP::SQLSandbox.new(store.path).query(query).rows.should eq rows
      end
    end

    ["DELETE FROM expenses", "PRAGMA query_only = OFF", "ATTACH 'x.db' AS x", "VACUUM INTO '/tmp/x.db'",
     "SELECT 1; DELETE FROM expenses", "SELECT 1 /* ; */; SELECT 2", "EXPLAIN SELECT 1", "-- only a comment"].each do |query|
      it "refuses #{query.inspect} with SQLite's error" do
        expect_raises(Domain::ValidationError, "SQL error: ") { MCP::SQLSandbox.new(store.path).query(query) }
      end
    end

    it "stops reading after the row limit, even when the query comments out the wrapper's LIMIT" do
      query = "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n) SELECT x FROM n) LIMIT 100000000 /*"
      result = MCP::SQLSandbox.new(store.path).query(query)

      {result.rows.size, result.rows.last, result.truncated}.should eq({MCP::SQLSandbox::MAX_ROWS, [500_i64], true})
    end

    it "refuses a NUL character" do
      expect_invalid("The query contains a NUL character.") { MCP::SQLSandbox.new(store.path).query("SELECT 1\0; DROP TABLE expenses") }
    end
  end

  it "needs a database file, since it attaches the file" do
    expect_raises(Domain::ValidationError, ":memory:") { MCP::SQLSandbox.new(":memory:").query("SELECT 1") }
  end

  describe "the sandbox connection" do
    around_each do |example|
      with_temp_dir do |dir|
        Household.within(Store.open(File.join(dir, "zipfelkasse.db"))) { example.run }
      end
    end

    it "allows no write, no schema change and no access to the file, even with query_only off" do
      household.create(household.equal("Rewe", 3000, "2026-09-01", household.anna, household.anna, household.ben))
      copy = File.join(File.dirname(store.path), "copy.db")
      before = File.read(store.path)

      MCP::SQLSandbox.new(store.path).with_sandbox(Time.instant + 5.seconds) do |connection|
        [
          "INSERT INTO participants (name, created_at) VALUES ('X', 'x')",
          "UPDATE expenses SET amount_cents = 1",
          "DELETE FROM expenses",
          "CREATE TABLE t (x)",
          "CREATE TEMP TABLE t (x)",
          "ATTACH DATABASE '#{store.path}' AS real",
          "ATTACH DATABASE 'file:#{store.path}?mode=ro' AS real",
          "VACUUM INTO '#{copy}'",
        ].each do |statement|
          expect_raises(SQLite3::Exception) { connection.exec(statement) }
        end
        File.exists?(copy).should be_false

        connection.exec("PRAGMA query_only = OFF")
        expect_raises(SQLite3::Exception) { connection.exec("ATTACH DATABASE '#{store.path}' AS real") }
        connection.exec("DELETE FROM expenses")
      end

      File.read(store.path).should eq before
      store.list_expenses.size.should eq 1
    end

    it "embeds a query as a subquery, where only a SELECT is possible" do
      MCP::SQLSandbox.new(store.path).with_sandbox(Time.instant + 5.seconds) do |connection|
        ["DELETE FROM expenses", "PRAGMA query_only = OFF", "SELECT 1) SELECT 1; ATTACH 'x' AS y; SELECT (1"].each do |body|
          expect_raises(Exception) { MCP::SQLSandbox.select_rows(connection, body) }
        end
      end
    end
  end
end
