defmodule Zipfelkasse.Repo.Migrations.CreateRecurringExpenses do
  use Ecto.Migration

  def change do
    create table(:recurring_expenses) do
      add :template, :map, null: false

      add :frequency, :string,
        null: false,
        check: %{
          name: "recurring_expenses_frequency_check",
          expr: "frequency IN ('weekly', 'monthly', 'yearly')"
        }

      add :start_date, :date, null: false
      add :next_date, :date, null: false

      add :active, :boolean,
        null: false,
        default: true,
        check: %{name: "recurring_expenses_active_check", expr: "active IN (0, 1)"}

      add :created_by_id, references(:participants)

      timestamps()
    end

    create index(:recurring_expenses, [:next_date], where: "active = 1")
  end
end
