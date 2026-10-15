defmodule Zipfelkasse.Repo.Migrations.CreateExpenses do
  use Ecto.Migration

  def change do
    create table(:expenses) do
      add :title, :string, null: false
      add :title_folded, :string, null: false
      add :date, :date, null: false
      add :category_id, references(:categories)
      add :paid_by_id, references(:participants), null: false
      add :notes, :string, null: false, default: ""
      add :notes_folded, :string, null: false, default: ""

      add :reimbursement, :boolean,
        null: false,
        default: false,
        check: %{name: "expenses_reimbursement_check", expr: "reimbursement IN (0, 1)"}

      add :split_mode, :string,
        null: false,
        check: %{
          name: "expenses_split_mode_check",
          expr: "split_mode IN ('equal', 'shares', 'percent', 'amount')"
        }

      add :amount_cents, :integer,
        null: false,
        check: %{name: "expenses_amount_cents_check", expr: "amount_cents > 0"}

      add :original_amount, :integer, null: false
      add :original_currency, :string, null: false, default: "EUR"
      add :fx_rate, :real, null: false, default: 1.0

      add :fx_source, :string,
        check: %{name: "expenses_fx_source_check", expr: "fx_source IN ('ecb', 'manual')"}

      add :recurring_expense_id, references(:recurring_expenses, on_delete: :nilify_all)
      add :deleted_at, :utc_datetime_usec

      timestamps()
    end

    create index(:expenses, ["date DESC", "id DESC"],
             name: :expenses_date_index,
             where: "deleted_at IS NULL"
           )

    create index(:expenses, [:paid_by_id])
    create index(:expenses, [:category_id])

    create unique_index(:expenses, [:recurring_expense_id, :date],
             where: "recurring_expense_id IS NOT NULL"
           )
  end
end
