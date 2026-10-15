defmodule Zipfelkasse.Repo.Migrations.CreateYnabTransactions do
  use Ecto.Migration

  def change do
    create table(:ynab_transactions, primary_key: false, options: "WITHOUT ROWID") do
      add :expense_id, references(:expenses), null: false, primary_key: true
      add :participant_id, references(:participants), null: false, primary_key: true
      add :ynab_transaction_id, :string

      add :state, :string,
        null: false,
        default: "unknown",
        check: %{
          name: "ynab_transactions_state_check",
          expr: "state IN ('unknown', 'synced', 'pending', 'retarget', 'failed', 'delete_failed')"
        }

      add :fingerprint, :string
      add :synced_at, :utc_datetime_usec
      add :last_error, :string
    end

    create index(:ynab_transactions, [:participant_id])
  end
end
