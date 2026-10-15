defmodule Zipfelkasse.Repo.Migrations.CreateCategories do
  use Ecto.Migration

  def change do
    create table(:categories) do
      add :name, :string,
        null: false,
        collate: :nocase,
        check: %{name: "categories_name_check", expr: "length(trim(name)) > 0"}

      add :position, :integer, null: false, default: 0
      add :archived_at, :utc_datetime_usec

      timestamps()
    end

    create unique_index(:categories, [:name])
  end
end
