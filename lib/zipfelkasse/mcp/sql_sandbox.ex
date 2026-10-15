defmodule Zipfelkasse.MCP.SqlSandbox do
  @moduledoc """
  Runs one query on an in-memory copy of the tables the MCP may see; the YNAB tables with their
  tokens are never copied. The copy comes from the database file, attached read-only and
  detached again; then the connection only reads (`query_only`) and may neither attach nor run
  pragmas. The query is embedded as a subquery that SQLite must compile whole, so only a single
  SELECT runs, and is cancelled after 2 seconds, the copy included.
  """

  alias Exqlite.Sqlite3
  alias Zipfelkasse.MCP.Tools

  @exposed ~w(participants categories expenses expense_shares recurring_expenses activities fx_rates settings)
  @max_query 100_000
  @max_cell 2000
  # Enough bytes for 2000 characters of up to four bytes each.
  @max_cell_bytes 4 * @max_cell
  @max_result 8 * 1024 * 1024
  @timeout 2000
  @cancel_again 50

  @type result :: %{
          columns: [String.t()],
          rows: [list()],
          truncated: boolean(),
          note: String.t() | nil
        }

  @doc "The tables the MCP may see."
  def exposed_tables, do: @exposed

  @doc "The CREATE statements of the visible tables and their indexes in the database of `repo`."
  def schema(repo) do
    %{rows: rows} =
      repo.query!(
        "SELECT tbl_name, sql FROM sqlite_schema WHERE type IN ('table', 'index') AND sql IS NOT NULL " <>
          "ORDER BY type DESC, rowid"
      )

    for [table, sql] <- rows, table in @exposed, do: sql
  end

  @doc """
  Runs `query` on a copy of the database file at `path`: at most 500 rows and 8 MiB, texts cut
  at 2000 characters, blobs and infinite numbers as text; a cut result has a note. Errors are
  messages for the client.
  """
  @spec query(String.t() | nil, String.t(), timeout()) :: {:ok, result()} | {:error, String.t()}
  def query(path, query, timeout \\ @timeout) do
    cond do
      byte_size(query) > @max_query ->
        {:error, "The query is too long (at most #{@max_query} bytes)."}

      String.contains?(query, <<0>>) ->
        {:error, "The query contains a NUL character."}

      path in [nil, "", ":memory:"] ->
        {:error, "sql_query needs a database file (not available with :memory:)."}

      true ->
        sandboxed(path, Regex.replace(~r/[; \t\n\r]+\z/, String.trim(query), ""), timeout)
    end
  end

  defp sandboxed(path, body, timeout) do
    {:ok, db} = Sqlite3.open(":memory:")
    parent = self()
    ref = make_ref()

    {timer, monitor} =
      spawn_monitor(fn ->
        receive do
          :stop -> :ok
        after
          timeout ->
            send(parent, {ref, :timeout})
            cancel_until_stopped(db)
        end
      end)

    result =
      try do
        with :ok <- copy(db, path), do: select(db, body)
      after
        send(timer, :stop)

        receive do
          {:DOWN, ^monitor, _type, _pid, _reason} -> :ok
        end

        Sqlite3.close(db)
      end

    receive do
      {^ref, :timeout} ->
        {:error,
         "The query was aborted after #{div(timeout, 1000)} s. Please narrow it down (WHERE, LIMIT) or simplify it."}
    after
      0 -> translate(result)
    end
  end

  # Every SQLite call clears an earlier cancel, so one landing between two calls would be lost.
  defp cancel_until_stopped(db) do
    Sqlite3.cancel(db)

    receive do
      :stop -> :ok
    after
      @cancel_again -> cancel_until_stopped(db)
    end
  end

  defp translate({:ok, _result} = ok), do: ok

  defp translate({:error, message}) do
    if message =~ "too big",
      do: {:error, "The result is too large. Please query fewer columns/rows."},
      else: {:error, "SQL error: " <> message}
  end

  defp copy(db, path) do
    uri =
      "file:" <>
        URI.encode(Path.expand(path), &(URI.char_unreserved?(&1) or &1 == ?/)) <> "?mode=ro"

    with :ok <- run(db, "ATTACH DATABASE ?1 AS src", [uri]),
         :ok <- Sqlite3.execute(db, "BEGIN"),
         {:ok, objects} <-
           rows(
             db,
             "SELECT type, name, tbl_name, sql FROM src.sqlite_schema WHERE type IN ('table', 'index') " <>
               "AND sql IS NOT NULL ORDER BY type DESC, rowid"
           ),
         :ok <-
           create(
             db,
             Enum.filter(objects, fn [_type, _name, table, _sql] -> table in @exposed end)
           ),
         :ok <- Sqlite3.execute(db, "COMMIT"),
         :ok <- Sqlite3.execute(db, "DETACH DATABASE src"),
         :ok <- Sqlite3.execute(db, "PRAGMA query_only = 1") do
      Sqlite3.set_authorizer(db, [:attach, :detach, :pragma])
    end
  end

  defp create(db, objects) do
    Enum.reduce_while(objects, :ok, fn object, :ok ->
      case create_one(db, object) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp create_one(db, ["table", name, _table, sql]) do
    with :ok <- Sqlite3.execute(db, sql),
         do: Sqlite3.execute(db, ~s|INSERT INTO main."#{name}" SELECT * FROM src."#{name}"|)
  end

  defp create_one(db, [_index, _name, _table, sql]), do: Sqlite3.execute(db, sql)

  # SQLite compiles only a first statement: binding the randomly named LIMIT proves it was all.
  defp select(db, body) do
    limit = ":limit_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    # The newline ends a trailing "--" comment.
    from = "FROM (\n#{body}\n) LIMIT #{limit}"

    with {:ok, columns} <- columns(db, "SELECT * " <> from),
         {:ok, statement} <-
           Sqlite3.prepare(db, "SELECT #{Enum.map_join(columns, ", ", &shown/1)} " <> from) do
      fetch(db, statement, columns, limit)
    end
  end

  defp columns(db, sql) do
    with {:ok, statement} <- Sqlite3.prepare(db, sql) do
      columns = Sqlite3.columns(db, statement)
      Sqlite3.release(db, statement)
      columns
    end
  end

  # The driver hands back neither blobs nor infinite reals; long texts are cut before leaving SQLite.
  defp shown(column) do
    c = ~s|"| <> String.replace(column, ~s|"|, ~s|""|) <> ~s|"|

    "CASE typeof(#{c}) WHEN 'blob' THEN '[BLOB, ' || length(#{c}) || ' Bytes]' " <>
      "WHEN 'text' THEN CAST(substr(CAST(#{c} AS BLOB), 1, #{@max_cell_bytes}) AS TEXT) " <>
      "WHEN 'real' THEN CASE WHEN #{c} > 1.7976931348623157e308 THEN 'Infinity' " <>
      "WHEN #{c} < -1.7976931348623157e308 THEN '-Infinity' ELSE #{c} END ELSE #{c} END"
  end

  defp fetch(db, statement, columns, limit) do
    with :ok <- bind_limit(statement, limit),
         {:ok, rows, cut} <- fetch_rows(db, statement, Tools.max_rows(), [], 0) do
      {:ok,
       %{
         columns: columns,
         rows: rows,
         truncated: cut != nil,
         note: note(cut, length(rows))
       }}
    end
  rescue
    ArgumentError -> {:error, "a value of the result cannot be shown"}
  after
    Sqlite3.release(db, statement)
  end

  defp bind_limit(statement, name) do
    Sqlite3.bind(statement, %{name => Tools.max_rows() + 1})
  rescue
    ArgumentError ->
      {:error, "only a single SELECT without parameters is allowed, with nothing after it"}
  end

  # Row by row, so a result never holds more than one row beyond its limits.
  defp fetch_rows(db, statement, left, rows, bytes) do
    case Sqlite3.step(db, statement) do
      :done ->
        {:ok, Enum.reverse(rows), nil}

      {:row, _row} when left == 0 ->
        {:ok, Enum.reverse(rows), :rows}

      {:row, row} ->
        row = Enum.map(row, &cell/1)
        bytes = bytes + Enum.sum_by(row, &size/1)

        if bytes > @max_result,
          do: {:ok, Enum.reverse(rows), :size},
          else: fetch_rows(db, statement, left - 1, [row | rows], bytes)

      {:error, message} ->
        {:error, message}
    end
  end

  defp size(value) when is_binary(value), do: byte_size(value)
  defp size(_value), do: 8

  defp note(nil, _count), do: nil

  defp note(:rows, count),
    do:
      "There are more than #{count} rows; only the first #{count} are included. " <>
        "Please aggregate or narrow down with WHERE/LIMIT."

  defp note(:size, count),
    do:
      "The result is larger than 8 MiB; only the first #{count} rows are included. " <>
        "Please query fewer columns or rows."

  # A text cut at its byte limit may end in the middle of a character.
  defp cell(value) when is_binary(value) do
    text =
      case :unicode.characters_to_binary(value) do
        text when is_binary(text) -> text
        {:incomplete, text, _rest} when byte_size(value) == @max_cell_bytes -> text
        _invalid -> nil
      end

    cond do
      is_nil(text) -> "[BLOB, #{byte_size(value)} Bytes]"
      byte_size(text) > @max_cell -> String.slice(text, 0, @max_cell)
      true -> text
    end
  end

  defp cell(value), do: value

  defp run(db, sql, params) do
    with {:ok, statement} <- Sqlite3.prepare(db, sql) do
      try do
        with :ok <- Sqlite3.bind(statement, params),
             :done <- Sqlite3.step(db, statement),
             do: :ok
      after
        Sqlite3.release(db, statement)
      end
    end
  end

  defp rows(db, sql) do
    with {:ok, statement} <- Sqlite3.prepare(db, sql) do
      try do
        Sqlite3.fetch_all(db, statement)
      after
        Sqlite3.release(db, statement)
      end
    end
  end
end
