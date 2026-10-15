defmodule Zipfelkasse.MigrationsTest do
  use ExUnit.Case, async: true

  alias Zipfelkasse.{Repo, TestMigrations}

  @moduletag :tmp_dir

  @tables ~w(activities categories expense_shares expenses fx_rates participants
             recurring_expenses settings ynab_category_mappings ynab_connections ynab_transactions)

  defp open!(path) do
    repo =
      start_supervised!(
        {Repo, name: nil, database: path, pool: DBConnection.ConnectionPool, pool_size: 1},
        id: {Repo, path}
      )

    Repo.put_dynamic_repo(repo)
    repo
  end

  defp rows(sql), do: Repo.query!(sql).rows

  test "the migrations build every table and seed a working database on an empty file", %{
    tmp_dir: dir
  } do
    repo = open!(Path.join(dir, "empty.sqlite3"))

    assert length(TestMigrations.run!(repo)) == 12

    assert List.flatten(rows("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")) --
             ~w(schema_migrations sqlite_sequence) == @tables

    assert rows("SELECT name, position FROM categories ORDER BY id") == [
             ["Lebensmittel", 10],
             ["Restaurant", 20],
             ["Haushalt", 30],
             ["Miete & Nebenkosten", 40],
             ["Transport", 50],
             ["Reisen", 60],
             ["Freizeit", 70],
             ["Gesundheit", 80],
             ["Geschenke", 90],
             ["Sonstiges", 1000]
           ]

    assert [[1, "Zipfelkasse", inserted_at]] =
             rows("SELECT id, group_name, inserted_at FROM settings")

    assert {:ok, _time, 0} = DateTime.from_iso8601(inserted_at)

    schema = rows("SELECT name, sql FROM sqlite_master ORDER BY name")
    assert TestMigrations.run!(repo) == []
    assert rows("SELECT name, sql FROM sqlite_master ORDER BY name") == schema
  end

  test "names are unique regardless of ASCII case and checks carry names", %{tmp_dir: dir} do
    TestMigrations.run!(open!(Path.join(dir, "constraints.sqlite3")))

    assert_raise Exqlite.Error, ~r/UNIQUE constraint failed: categories.name/, fn ->
      Repo.query!(
        "INSERT INTO categories (name, inserted_at, updated_at) VALUES ('sonstiges', 'x', 'x')"
      )
    end

    assert_raise Exqlite.Error, ~r/CHECK constraint failed: fx_rates_rate_check/, fn ->
      Repo.query!(
        "INSERT INTO fx_rates (currency, source, date, rate) VALUES ('USD', 'ecb', '2026-10-01', 0)"
      )
    end

    assert_raise Exqlite.Error, ~r/CHECK constraint failed: fx_rates_source_check/, fn ->
      Repo.query!(
        "INSERT INTO fx_rates (currency, source, date, rate) VALUES ('USD', 'foo', '2026-10-01', 1)"
      )
    end
  end
end
