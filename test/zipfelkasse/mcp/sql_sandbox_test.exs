defmodule Zipfelkasse.MCP.SqlSandboxTest do
  use ExUnit.Case, async: true

  import Zipfelkasse.Fixtures

  alias Zipfelkasse.MCP.SqlSandbox
  alias Zipfelkasse.{Repo, TestMigrations}
  alias Zipfelkasse.Ynab.Connections

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "zipfelkasse.sqlite3")

    repo =
      start_supervised!(
        {Repo,
         name: nil,
         database: path,
         pool: DBConnection.ConnectionPool,
         pool_size: 1,
         journal_mode: :wal},
        id: {Repo, path}
      )

    Repo.put_dynamic_repo(repo)
    TestMigrations.run!(repo)
    h = household()
    create!(equal(h, "Rewe", 3000, "2026-09-01", h.anna, [h.anna, h.ben]))
    {:ok, _reset?} = Connections.put_token(h.anna, "secret-token-123")
    %{path: path}
  end

  defp rows(path, query) do
    {:ok, result} = SqlSandbox.query(path, query)
    result.rows
  end

  defp error(path, query) do
    {:error, message} = SqlSandbox.query(path, query)
    message
  end

  test "runs a single SELECT, with trailing semicolons and comments", %{path: path} do
    for {query, expected} <- [
          {"  select 1 AS x ;  ", [[1]]},
          {"SELECT 1 AS x;;", [[1]]},
          {"SELECT 1 AS x -- end", [[1]]},
          {"/* a; b */ SELECT ';' AS x", [[";"]]},
          {"WITH y AS (SELECT 2 AS x) SELECT * FROM y", [[2]]},
          {"(SELECT 1)", [[1]]},
          {~s|SELECT 'it''s; fine' AS "a;b", [c;d] FROM (SELECT 1 AS [c;d])|, [["it's; fine", 1]]}
        ],
        do: assert(rows(path, query) == expected, query)
  end

  test "sees the data, but no YNAB table", %{path: path} do
    assert rows(path, "SELECT title, amount_cents FROM expenses WHERE deleted_at IS NULL") == [
             ["Rewe", 3000]
           ]

    assert rows(
             path,
             "SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite%' ORDER BY name"
           ) ==
             Enum.map(Enum.sort(SqlSandbox.exposed_tables()), &[&1])

    assert error(path, "SELECT * FROM ynab_connections") =~
             "SQL error: no such table: ynab_connections"

    assert error(path, "SELECT * FROM main.ynab_connections") =~ "no such table"
    assert error(path, "SELECT * FROM src.expenses") =~ "no such table"

    refute rows(path, "SELECT group_concat(sql) FROM sqlite_schema")
           |> inspect()
           |> String.downcase() =~ "ynab"
  end

  test "names columns as SQLite does and shows every kind of value", %{path: path} do
    assert {:ok,
            %{
              columns: ["1", "1:1", "x", "x:1"],
              rows: [[1, 1, "a", "b"]],
              truncated: false,
              note: nil
            }} = SqlSandbox.query(path, "SELECT 1, 1, 'a' AS x, 'b' AS x")

    assert rows(
             path,
             "SELECT 42 AS i, 2.5 AS r, 0.1 + 0.2 AS s, 1e30 AS big, 'a<&>b' AS t, NULL AS n, x'00ff' AS b, " <>
               "x'41' AS a, json_object('a', 1) AS j, 9007199254740993 AS l, 1e999 AS inf, -1e999 AS neg"
           ) == [
             [
               42,
               2.5,
               0.30000000000000004,
               1.0e30,
               "a<&>b",
               nil,
               "[BLOB, 2 Bytes]",
               "[BLOB, 1 Bytes]",
               ~s({"a":1}),
               9_007_199_254_740_993,
               "Infinity",
               "-Infinity"
             ]
           ]

    assert [[5000, long, umlaut]] =
             rows(
               path,
               "SELECT length(substr(hex(zeroblob(2500)), 1, 5000)) AS n, substr(hex(zeroblob(2500)), 1, 5000) AS t, " <>
                 "'ä' || substr(hex(zeroblob(1500)), 1, 2999) AS u"
             )

    assert long == String.duplicate("0", 2000)
    assert umlaut == "ä" <> String.duplicate("0", 1999)

    assert rows(
             path,
             "SELECT replace(printf('%.*c', 5000, 'x'), 'x', '€') AS e, CAST(x'41ff' AS TEXT) AS bad"
           ) == [[String.duplicate("€", 2000), "[BLOB, 2 Bytes]"]]
  end

  test "cuts a huge value inside SQLite, so it never reaches the VM whole", %{path: path} do
    {pid, monitor} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{
          size: 2_000_000,
          kill: true,
          error_logger: false,
          include_shared_binaries: true
        })

        exit(SqlSandbox.query(path, "SELECT printf('%.*c', 50000000, 'x') AS big, 1 AS n"))
      end)

    assert_receive {:DOWN, ^monitor, :process, ^pid, {:ok, %{rows: [[big, 1]]}}}, 5000
    assert big == String.duplicate("x", 2000)
  end

  test "stops a result at 8 MiB", %{path: path} do
    cells = Enum.map_join(1..10, ", ", &"x AS c#{&1}")

    assert {:ok, %{rows: rows, truncated: true, note: note}} =
             SqlSandbox.query(
               path,
               "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n LIMIT 500), " <>
                 "v(x) AS (SELECT printf('%.*c', 3000, 'x')) SELECT #{cells} FROM n, v"
             )

    assert length(rows) == div(8 * 1024 * 1024, 10 * 2000)

    assert note ==
             "The result is larger than 8 MiB; only the first #{length(rows)} rows are included. " <>
               "Please query fewer columns or rows."
  end

  test "refuses a query longer than 100,000 bytes", %{path: path} do
    query = "SELECT 1 AS x" <> String.duplicate(" ", 100_000)

    assert error(path, query) == "The query is too long (at most 100000 bytes)."
  end

  test "returns at most 500 rows", %{path: path} do
    assert {:ok, %{rows: rows, truncated: true, note: note}} =
             SqlSandbox.query(
               path,
               "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n LIMIT 1000) SELECT i FROM n ORDER BY i DESC"
             )

    assert {length(rows), hd(rows), List.last(rows)} == {500, [1000], [501]}

    assert note ==
             "There are more than 500 rows; only the first 500 are included. " <>
               "Please aggregate or narrow down with WHERE/LIMIT."

    assert {:ok, %{rows: rows, truncated: false}} =
             SqlSandbox.query(
               path,
               "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n LIMIT 500) SELECT i FROM n"
             )

    assert length(rows) == 500
  end

  test "refuses anything but a single SELECT with an SQL error", %{path: path} do
    for query <- [
          "DELETE FROM expenses",
          "INSERT INTO settings VALUES (2, 'a', 'b', 'c')",
          "UPDATE participants SET name = 'x'",
          "DROP TABLE expenses",
          "ATTACH DATABASE 'x.db' AS x",
          "PRAGMA query_only = OFF",
          "PRAGMA table_info(expenses)",
          "VACUUM INTO '/tmp/x.db'",
          "CREATE TABLE x (a)",
          "EXPLAIN SELECT 1",
          "-- only a comment",
          "/* SELECT 1 */",
          "SELEKT 1",
          "BEGIN",
          "DETACH src",
          "SELECT 1; SELECT 2",
          "SELECT 1; DELETE FROM expenses",
          "SELECT 1 /* ; */; ATTACH 'x' AS y",
          "WITH x AS (SELECT 1) SELECT * FROM x; DROP TABLE expenses",
          "SELECT 1 AS one; -- done",
          "SELECT count(*) FROM pragma_database_list"
        ],
        do: assert(String.starts_with?(error(path, query), "SQL error: "), query)

    assert error(path, "WITH d AS (SELECT 1) DELETE FROM expenses") ==
             ~s(SQL error: near "DELETE": syntax error)

    for query <- [
          "SELECT 1) ; DELETE FROM expenses",
          "SELECT 1 AS x) ; DELETE FROM expenses; SELECT (1",
          "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n) SELECT x FROM n) LIMIT 100000000 /*",
          "SELECT ?",
          "SELECT :limit_0000000000000000) ; DELETE FROM expenses"
        ],
        do:
          assert(
            error(path, query) ==
              "SQL error: only a single SELECT without parameters is allowed, with nothing after it",
            query
          )

    assert error(path, "SELECT 1\u0000; DROP TABLE expenses") ==
             "The query contains a NUL character."

    assert rows(path, "SELECT count(*) FROM expenses") == [[1]]
  end

  test "aborts a slow query after the timeout and stays usable", %{path: path} do
    slow =
      "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 2000000000) SELECT count(*) FROM n"

    {elapsed, result} = :timer.tc(fn -> SqlSandbox.query(path, slow, 300) end, :millisecond)

    assert result ==
             {:error,
              "The query was aborted after 0 s. Please narrow it down (WHERE, LIMIT) or simplify it."}

    assert elapsed >= 250 and elapsed < 3000
    assert rows(path, "SELECT 1 AS ok") == [[1]]
  end

  test "keeps cancelling a slow query when the deadline falls between two SQLite calls", %{
    path: path
  } do
    slow =
      "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 2000000000) SELECT count(*) FROM n"

    for timeout <- 0..40 do
      task = Task.async(fn -> SqlSandbox.query(path, slow, timeout) end)
      result = Task.yield(task, 2000) || Task.shutdown(task, :brutal_kill)

      assert match?({:ok, {:error, "The query was aborted after 0 s." <> _hint}}, result),
             "timeout #{timeout} ms: #{inspect(result)}"
    end
  end

  test "needs a database file, since it attaches the file" do
    assert SqlSandbox.query(":memory:", "SELECT 1") ==
             {:error, "sql_query needs a database file (not available with :memory:)."}
  end

  test "the copy allows no write, no attach, no pragma and no extension, and leaves the files as they were",
       %{path: path} do
    files = fn -> Enum.map(["", "-wal"], &File.read!(path <> &1)) end
    before = files.()

    for query <- [
          "SELECT * FROM (SELECT 1) WHERE (SELECT count(*) FROM pragma_table_list) > 0",
          "SELECT load_extension('/tmp/x')"
        ],
        do: assert(error(path, query) =~ "not authorized", query)

    assert files.() == before
  end

  test "no visible table holds a YNAB token", %{path: path} do
    for table <- SqlSandbox.exposed_tables(),
        do: refute(inspect(rows(path, ~s(SELECT * FROM "#{table}"))) =~ "secret-token-123", table)
  end
end
