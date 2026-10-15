defmodule Zipfelkasse.Release do
  @moduledoc "Tasks run from the release, where Mix is not available."

  @app :zipfelkasse

  # A second connection would race the first to switch an empty file to WAL.
  @repo_opts [pool_size: 1]

  def migrate do
    Application.ensure_loaded(@app)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true), @repo_opts)
    end

    :ok
  end
end
