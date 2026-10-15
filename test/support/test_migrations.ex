defmodule Zipfelkasse.TestMigrations do
  @moduledoc "Runs the app's migrations on another database than the sandboxed one."

  alias Zipfelkasse.Repo

  def run!(repo, opts \\ [all: true]),
    do: Ecto.Migrator.run(Repo, migrations(), :up, opts ++ [dynamic_repo: repo, log: false])

  defp migrations do
    :global.trans({__MODULE__, self()}, fn ->
      with nil <- :persistent_term.get(__MODULE__, nil) do
        migrations = Enum.map(files(), &compile/1)
        :persistent_term.put(__MODULE__, migrations)
        migrations
      end
    end)
  end

  defp files,
    do: Repo |> Ecto.Migrator.migrations_path() |> Path.join("*.exs") |> Path.wildcard()

  defp compile(file) do
    {version, "_" <> _} = Integer.parse(Path.basename(file))
    [{module, _binary}] = Code.compile_file(file)
    {version, module}
  end
end
