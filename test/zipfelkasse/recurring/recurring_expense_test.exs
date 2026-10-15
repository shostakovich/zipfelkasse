defmodule Zipfelkasse.Recurring.RecurringExpenseTest do
  use Zipfelkasse.DataCase

  import Zipfelkasse.Fixtures

  alias Zipfelkasse.Expenses
  alias Zipfelkasse.Expenses.Expense
  alias Zipfelkasse.Recurring.RecurringExpense

  test "keeps the input of an expense as its template" do
    h = household()

    expense =
      create!(foreign(h, "Miete", 100_000, "CHF", 0.94, "2026-01-31", h.anna, [h.anna, h.ben]))

    input = Expenses.input(expense)

    template =
      %RecurringExpense.Template{}
      |> RecurringExpense.template_changeset(Map.delete(input, :date))
      |> apply_changes()

    rule =
      Repo.insert!(%RecurringExpense{
        template: template,
        frequency: :monthly,
        start_date: ~D[2026-01-31],
        next_date: ~D[2026-02-28],
        created_by_id: h.anna
      })

    template = Repo.get!(RecurringExpense, rule.id).template

    assert Map.take(template, [
             :title,
             :original_amount,
             :original_currency,
             :fx_rate,
             :fx_source,
             :split_mode
           ]) ==
             %{
               title: "Miete",
               original_amount: 100_000,
               original_currency: "CHF",
               fx_rate: 0.94,
               fx_source: :ecb,
               split_mode: :equal
             }

    assert Enum.map(template.parts, &Map.take(&1, [:participant_id, :weight])) == input.parts

    assert {:ok, _occurrence} =
             Expenses.create_expense(
               nil,
               Map.put(Map.from_struct(template), :date, ~D[2026-02-28])
             )
  end

  test "a template has every field of an expense input but date and parts" do
    fields = RecurringExpense.template_fields()

    assert Enum.sort(fields) ==
             Enum.sort(RecurringExpense.Template.__schema__(:fields) -- [:parts])

    assert fields -- Expense.__schema__(:fields) == []
  end
end
