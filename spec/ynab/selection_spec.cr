require "../spec_helper"

private def expense(on : String, created : String) : Store::Expense
  input = Store::ExpenseInput.new(title: "Kino", date: date(on), paid_by: 1_i64, amount_cents: 1000_i64)
  build_expense(7_i64, input, [Domain::Share.new(1_i64, amount_cents: 500_i64)], at: Time.parse_utc(created, "%F %R"))
end

private def includes?(selection : YNAB::Selection, expense : Store::Expense) : Bool
  selection.includes?(expense, YNAB.posting_for(expense, 1_i64).not_nil!)
end

describe YNAB::Selection do
  today = date("2026-10-02")
  start = date("2026-09-10")
  connected_at = Time.utc(2026, 9, 20, 10)

  it "takes every past expense while YNAB is not set up" do
    includes?(YNAB::Selection.new(today), expense("2020-01-01", "2020-01-01 10:00")).should be_true
  end

  it "leaves out expenses dated after today, which YNAB would reject" do
    includes?(YNAB::Selection.new(today), expense("2026-10-03", "2026-09-01 10:00")).should be_false
  end

  it "takes expenses dated on or after the start date" do
    selection = YNAB::Selection.new(today, start, connected_at)
    includes?(selection, expense("2026-09-10", "2026-09-01 10:00")).should be_true
    includes?(selection, expense("2026-09-09", "2026-09-01 10:00")).should be_false
  end

  it "takes an expense dated before the start date that was entered after the setup" do
    selection = YNAB::Selection.new(today, start, connected_at)
    includes?(selection, expense("2026-09-01", "2026-09-20 10:00")).should be_true
    includes?(selection, expense("2026-09-01", "2026-09-20 09:59")).should be_false
  end

  it "keeps an expense dated before the start date that is already in YNAB" do
    selection = YNAB::Selection.new(today, start, connected_at, Set{7_i64})
    includes?(selection, expense("2026-09-01", "2026-09-01 10:00")).should be_true
  end
end
