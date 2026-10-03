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

def with_expense_fixture(&)
  f = ExpenseFixture.new
  begin
    yield f
  ensure
    f.s.close
  end
end
