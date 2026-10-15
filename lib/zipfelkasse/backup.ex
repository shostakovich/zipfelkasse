defmodule Zipfelkasse.Backup do
  @moduledoc """
  Copies of the database (`VACUUM INTO`) in the backup directory, named by the UTC time:
  `zipfelkasse-20261014-030000.sqlite3`. The newest seven are kept. They hold the YNAB tokens,
  so only the owner can read them.
  """

  require Logger

  alias Zipfelkasse.Repo

  @prefix "zipfelkasse-"
  @suffix ".sqlite3"
  @keep 7

  @doc "Writes a backup into `dir` (the configured one by default) and removes the oldest."
  @spec run(String.t(), DateTime.t(), pos_integer()) :: {:ok, String.t()} | {:error, String.t()}
  def run(dir \\ dir(), now \\ DateTime.utc_now(), keep \\ @keep) do
    path = Path.join(dir, @prefix <> Calendar.strftime(now, "%Y%m%d-%H%M%S") <> @suffix)

    with :ok <- private_dir(dir),
         :ok <- private_file(path),
         :ok <- vacuum_into(path) do
      rotate(dir, keep)
      Logger.info("backup written: #{path}")
      {:ok, path}
    else
      {:error, reason} -> {:error, "backup #{path}: #{reason}"}
    end
  end

  defp dir, do: Application.fetch_env!(:zipfelkasse, :backup_dir)

  defp private_dir(dir) do
    with :ok <- File.mkdir_p(dir), :ok <- File.chmod(dir, 0o700) do
      :ok
    else
      {:error, reason} -> {:error, :file.format_error(reason)}
    end
  end

  # VACUUM INTO takes an empty file, so the copy is never readable by others; an existing one fails.
  defp private_file(path) do
    with {:ok, file} <- File.open(path, [:write, :exclusive]),
         :ok <- File.close(file),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      {:error, reason} -> {:error, :file.format_error(reason)}
    end
  end

  defp vacuum_into(path) do
    case Repo.query("VACUUM INTO ?", [path]) do
      {:ok, _result} ->
        :ok

      {:error, error} ->
        File.rm(path)
        {:error, Exception.message(error)}
    end
  end

  @doc "Removes all but the newest `keep` backups in `dir`, by name; other files stay."
  @spec rotate(String.t(), non_neg_integer()) :: :ok
  def rotate(dir, keep) do
    dir
    |> File.ls!()
    |> Enum.filter(&backup?(dir, &1))
    |> Enum.sort(:desc)
    |> Enum.drop(keep)
    |> Enum.each(&File.rm!(Path.join(dir, &1)))
  end

  defp backup?(dir, name) do
    String.starts_with?(name, @prefix) and String.ends_with?(name, @suffix) and
      match?({:ok, %File.Stat{type: :regular}}, File.lstat(Path.join(dir, name)))
  end
end
