defmodule Zipfelkasse.BackupTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Exqlite.Sqlite3
  alias Zipfelkasse.{Backup, Repo}

  @moduletag :tmp_dir

  defp backup(dir, now), do: Sandbox.unboxed_run(Repo, fn -> Backup.run(dir, now) end)

  defp names(dir), do: dir |> File.ls!() |> Enum.sort()

  defp count(path, table) do
    {:ok, conn} = Sqlite3.open(path, mode: :readonly)

    try do
      {:ok, statement} = Sqlite3.prepare(conn, "SELECT count(*) FROM #{table}")
      {:ok, [[count]]} = Sqlite3.fetch_all(conn, statement)
      count
    after
      Sqlite3.close(conn)
    end
  end

  test "writes backups named by the UTC time, keeps the newest seven and leaves other files alone",
       %{tmp_dir: tmp} do
    dir = Path.join(tmp, "backups")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "notiz.txt"), "x")

    paths =
      for day <- 1..9 do
        {:ok, path} = backup(dir, DateTime.new!(Date.new!(2026, 10, day), ~T[03:00:00]))
        path
      end

    assert List.first(paths) == Path.join(dir, "zipfelkasse-20261001-030000.sqlite3")

    assert names(dir) == [
             "notiz.txt" | Enum.map(3..9, &"zipfelkasse-2026100#{&1}-030000.sqlite3")
           ]

    assert count(List.last(paths), "categories") == 10
  end

  test "makes backups and their directory readable by the owner only and logs them",
       %{tmp_dir: tmp} do
    dir = Path.join(tmp, "backups")
    path = Path.join(dir, "zipfelkasse-20261014-010000.sqlite3")
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    log = capture_log(fn -> assert backup(dir, ~U[2026-10-14 01:00:00Z]) == {:ok, path} end)

    assert log =~ "backup written: #{path}"

    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(dir).mode, 0o777) == 0o700
  end

  test "refuses to overwrite an existing file", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "zipfelkasse-20261014-010000.sqlite3"), "old")

    assert {:error, "backup " <> _reason} = backup(dir, ~U[2026-10-14 01:00:00Z])
    assert File.read!(Path.join(dir, "zipfelkasse-20261014-010000.sqlite3")) == "old"
  end

  test "rotates only regular backup files", %{tmp_dir: dir} do
    other = Path.join(dir, "elsewhere.sqlite3")
    File.write!(other, "x")
    File.ln_s!(other, Path.join(dir, "zipfelkasse-20000101-000000.sqlite3"))

    for day <- ~w(20260101 20260102),
        do: File.write!(Path.join(dir, "zipfelkasse-#{day}-000000.sqlite3"), "x")

    Backup.rotate(dir, 1)

    assert names(dir) == [
             "elsewhere.sqlite3",
             "zipfelkasse-20000101-000000.sqlite3",
             "zipfelkasse-20260102-000000.sqlite3"
           ]
  end
end
