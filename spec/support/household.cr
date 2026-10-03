# Anna, Ben and Cleo and the default categories (Lebensmittel is the first,
# Restaurant the second) in a store.
class Household
  getter store : Store
  getter anna : Int64
  getter ben : Int64
  getter cleo : Int64
  getter food : Int64
  getter restaurant : Int64
  getter deps : Web::Deps
  getter fx = FakeFX.new

  def initialize(@store : Store = Store.open(":memory:"))
    @deps = Web::Deps.new(Config.new, @store)
    @deps.fx = @fx
    @anna = @store.create_participant(nil, "Anna")
    @ben = @store.create_participant(nil, "Ben")
    @cleo = @store.create_participant(nil, "Cleo")
    categories = @store.list_categories
    @food, @restaurant = categories[0].id, categories[1].id
  end

  def close : Nil
    @store.close
  end

  # Freezes the clock of the services working on this household.
  def now=(time : Time) : Time
    @deps.config.now = time
  end

  # An equal split among *who*, in the category Lebensmittel.
  def equal(title : String, cents : Int64, on : String, payer : Int64, *who : Int64) : Store::ExpenseInput
    Store::ExpenseInput.new(title: title, date: date(on), paid_by: payer, amount_cents: cents, category_id: food,
      parts: who.map { |id| Domain::Part.new(id) }.to_a)
  end

  # A reimbursement of *cents* from *payer* to *to*.
  def reimbursement(cents : Int64, on : String, payer : Int64, to : Int64) : Store::ExpenseInput
    Store::ExpenseInput.new(title: Domain::REIMBURSEMENT_TITLE, date: date(on), paid_by: payer, amount_cents: cents,
      reimbursement: true, parts: [Domain::Part.new(to)])
  end

  def create(input : Store::ExpenseInput, by : Int64? = anna) : Int64
    @store.create_expense(by, input)
  end

  # A foreign-currency input: *minor* in *currency* at *rate*, euro cents derived by the store.
  def foreign(title : String, minor : Int64, currency : String, rate : Float64, on : String, payer : Int64,
              *who : Int64) : Store::ExpenseInput
    input = equal(title, 0_i64, on, payer, *who)
    input.original_currency, input.original_amount_minor, input.fx_rate = currency, minor, rate
    input.fx_source = Domain::FXSource::Ecb
    input.amount_cents = Domain.to_eur_cents(minor, currency, rate)
    input
  end

  def self.within(store : Store = Store.open(":memory:"), & : ->) : Nil
    household = new(store)
    Current.household = household
    Current.store = household.store
    begin
      yield
    ensure
      household.close
    end
  end
end

# Every example of the group gets a fresh `household` and its `store`.
def use_household : Nil
  around_each do |example|
    Household.within { example.run }
  end
end

def household : Household
  Current.household
end

# An expense as the store returns it, built from an input.
def build_expense(id : Int64, input : Store::ExpenseInput, shares = [] of Domain::Share, category_name : String? = nil,
                  paid_by_name : String = "", at : Time = Time.utc(2026, 1, 1)) : Store::Expense
  Store::Expense.new(id: id, title: input.title, date: input.date.not_nil!, category_id: input.category_id,
    paid_by: input.paid_by.not_nil!, notes: input.notes, reimbursement: input.reimbursement?, split_mode: input.split_mode,
    amount_cents: input.amount_cents, original_amount_minor: input.original_amount_minor,
    original_currency: input.original_currency, fx_rate: input.fx_rate || 1.0, fx_source: input.fx_source,
    recurring_id: input.recurring_id, created_at: at, updated_at: at, deleted_at: nil, category_name: category_name,
    paid_by_name: paid_by_name, shares: shares)
end
