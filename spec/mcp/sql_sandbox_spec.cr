require "../spec_helper"

describe MCP::SQLSandbox do
  describe ".check_select" do
    {
      "SELECT 1"                                                  => "SELECT 1",
      "  select 1 ;  "                                            => "  select 1 ",
      "-- comment\nWITH x AS (SELECT 1) SELECT * FROM x;; -- end" => "-- comment\nWITH x AS (SELECT 1) SELECT * FROM x",
      "/* a; b */ SELECT ';' AS x"                                => "/* a; b */ SELECT ';' AS x",
      %(SELECT "a;b", [c;d], `e;f`)                               => %(SELECT "a;b", [c;d], `e;f`),
      "SELECT 'it''s; fine'"                                      => "SELECT 'it''s; fine'",
    }.each do |query, checked|
      it "accepts #{query.inspect}" do
        MCP::SQLSandbox.check_select(query).should eq checked
      end
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
    ].each do |query|
      it "rejects #{query.inspect}" do
        expect_raises(Domain::ValidationError) { MCP::SQLSandbox.check_select(query) }
      end
    end
  end

  it "needs a database file, since it attaches the file" do
    expect_raises(Domain::ValidationError, ":memory:") { MCP::SQLSandbox.new(":memory:").query("SELECT 1") }
  end

  describe "below the lexical check" do
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
