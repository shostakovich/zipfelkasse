defmodule Zipfelkasse.Repo.Migrations.CreateExpenseShares do
  use Ecto.Migration

  def change do
    create table(:expense_shares, primary_key: false, options: "WITHOUT ROWID") do
      add :expense_id, references(:expenses, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :participant_id, references(:participants), null: false, primary_key: true
      add :weight, :integer, null: false
      add :amount_cents, :integer, null: false
    end

    create index(:expense_shares, [:participant_id])
  end
end
