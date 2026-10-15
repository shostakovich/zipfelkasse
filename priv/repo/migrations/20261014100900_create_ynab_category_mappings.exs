defmodule Zipfelkasse.Repo.Migrations.CreateYnabCategoryMappings do
  use Ecto.Migration

  def change do
    create table(:ynab_category_mappings, primary_key: false, options: "WITHOUT ROWID") do
      add :participant_id, references(:participants), null: false, primary_key: true
      add :category_id, references(:categories), null: false, primary_key: true
      add :ynab_category_id, :string, null: false
    end
  end
end
