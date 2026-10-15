defmodule Zipfelkasse.Repo.Migrations.CreateActivities do
  use Ecto.Migration

  def change do
    create table(:activities) do
      add :actor_id, references(:participants)

      add :action, :string,
        null: false,
        check: %{
          name: "activities_action_check",
          expr:
            "action IN ('expense_created', 'expense_updated', 'expense_deleted', " <>
              "'settings_updated', 'recurring_created', 'recurring_deleted')"
        }

      add :expense_id, references(:expenses)
      add :details, :map, null: false, default: %{}

      timestamps(updated_at: false)
    end

    create index(:activities, [:expense_id])
  end
end
