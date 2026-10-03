require "./store_helper"

# Anna, Ben and Cleo plus the first seed category (Lebensmittel).
struct ExpenseFixture
  getter s : Zipfelkasse::Store
  getter anna : Int64
  getter ben : Int64
  getter cleo : Int64
  getter food : Int64

  def initialize(@s : Zipfelkasse::Store = new_test_store)
    @anna = must_participant(@s, "Anna")
    @ben = must_participant(@s, "Ben")
    @cleo = must_participant(@s, "Cleo")
    @food = @s.list_categories[0].id
  end

  # An equal split among who, in category food.
  def equal(title : String, amount : Int64, d : String, payer : Int64, *who : Int64) : Zipfelkasse::Store::ExpenseInput
    Zipfelkasse::Store::ExpenseInput.new(title: title, date: date(d), paid_by: payer, amount_cents: amount,
      category_id: food, parts: who.map { |id| Zipfelkasse::Domain::Part.new(id) }.to_a)
  end

  def must_create(input : Zipfelkasse::Store::ExpenseInput) : Int64
    s.create_expense(anna, input)
  end
end

# An expense as the store returns it, built from an input.
def build_expense(id : Int64, input : Zipfelkasse::Store::ExpenseInput, shares = [] of Zipfelkasse::Domain::Share,
                  category_name : String? = nil, paid_by_name : String = "", at : Time = Time.utc(2026, 1, 1)) : Zipfelkasse::Store::Expense
  Zipfelkasse::Store::Expense.new(id: id, title: input.title, date: input.date.not_nil!, category_id: input.category_id,
    paid_by: input.paid_by.not_nil!, notes: input.notes, reimbursement: input.reimbursement?, split_mode: input.split_mode,
    amount_cents: input.amount_cents, original_amount_minor: input.original_amount_minor,
    original_currency: input.original_currency, fx_rate: input.fx_rate || 1.0, fx_source: input.fx_source,
    recurring_id: input.recurring_id, created_at: at, updated_at: at, deleted_at: nil, category_name: category_name,
    paid_by_name: paid_by_name, shares: shares)
end

def with_expense_fixture(&)
  f = ExpenseFixture.new
  begin
    yield f
  ensure
    f.s.close
  end
end
