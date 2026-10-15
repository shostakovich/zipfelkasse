defmodule Zipfelkasse.Repo.Migrations.CreateSettings do
  use Ecto.Migration

  def change do
    create table(:settings, primary_key: false) do
      add :id, :integer, primary_key: true, check: %{name: "settings_id_check", expr: "id = 1"}
      add :group_name, :string, null: false

      timestamps()
    end
  end
end
