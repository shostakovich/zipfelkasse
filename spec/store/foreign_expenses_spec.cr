require "../spec_helper"

private def field_changes(expense_id : Int64) : Hash(String, Store::FieldChange)
  activities = store.list_activity(Store::ActivityFilter.new(expense_id: expense_id, limit: 1))
  return {} of String => Store::FieldChange unless activities.size == 1 && activities[0].action == Store::Action::ExpenseUpdated
  activities[0].details.changes.to_h { |change| {change.field, change} }
end

describe "Store expenses in a foreign currency" do
  use_household

  it "stores the original amount, the currency in capitals, the rate and its source" do
    input = household.foreign("Diner NYC", 10000, "usd", 1.0823, "2026-08-01", household.ben, household.anna, household.ben)

    expense = store.get_expense(store.create_expense(household.ben, input))

    {expense.foreign?, expense.original_currency, expense.amount_cents, expense.fx_rate, expense.fx_source}
      .should eq({true, "USD", 9240, 1.0823, Domain::FXSource::Ecb})
  end

  it "derives the euro amount from the original amount and the rate, whatever amount was given" do
    input = household.foreign("Diner NYC", 10000, "USD", 1.0823, "2026-08-01", household.ben, household.anna, household.ben)
    input.amount_cents = 1
    id = store.create_expense(household.ben, input)

    expense = store.get_expense(id)
    expense.amount_cents.should eq 9240
    (expense.share_of(household.anna) + expense.share_of(household.ben)).should eq 9240

    changed = expense.to_input
    changed.amount_cents = 1
    store.update_expense(household.ben, id, changed)
    store.get_expense(id).amount_cents.should eq 9240
  end

  it "rotates the extra euro cent of foreign amounts with the expense ID" do
    people = [household.anna, household.ben]
    4.times do
      # 10,00 USD at 0,999 = 10,01 €, split 5,00 USD : 5,00 USD
      input = household.foreign("Taxi", 1000, "USD", 0.999, "2026-09-01", household.anna, household.anna, household.ben)
      input.split_mode = Domain::SplitMode::Amount
      input.parts = [Domain::Part.new(household.anna, 500), Domain::Part.new(household.ben, 500)]
      id = store.create_expense(household.anna, input)

      expense = store.get_expense(id)
      expense.amount_cents.should eq 1001
      expense.share_of(people[id % 2]).should eq 501
    end
  end

  describe "split by amounts in the foreign currency" do
    expense_id = 0_i64

    before_each do
      input = household.foreign("Hotel", 1000, "USD", 1.1, "2026-08-01", household.anna, household.anna, household.ben, household.cleo)
      input.split_mode = Domain::SplitMode::Amount
      input.parts = [Domain::Part.new(household.cleo, 334), Domain::Part.new(household.anna, 333), Domain::Part.new(household.ben, 333)]
      expense_id = store.create_expense(household.anna, input)
    end

    it "stores the weights as entered and distributes the euro cents in proportion to them" do
      expense = store.get_expense(expense_id)

      expense.amount_cents.should eq 909
      (expense.share_of(household.anna) + expense.share_of(household.ben) + expense.share_of(household.cleo)).should eq 909
      expense.share_of(household.cleo).should eq 303
      expense.parts.map(&.weight).should eq [333, 333, 334]
    end

    it "logs nothing when it is saved unchanged" do
      entries = store.list_activity.size
      store.update_expense(household.anna, expense_id, store.get_expense(expense_id).to_input)

      store.list_activity.size.should eq entries
    end

    it "keeps the weights and changes the euro shares when the rate changes" do
      input = store.get_expense(expense_id).to_input
      input.fx_rate = 1.25
      store.update_expense(household.anna, expense_id, input)

      expense = store.get_expense(expense_id)
      {expense.amount_cents, expense.share_of(household.cleo), expense.parts[2].weight}.should eq({800, 267, 334})
    end

    it "lists changed shares in euros in the history" do
      input = store.get_expense(expense_id).to_input
      input.fx_rate = 1.25
      input.parts = [input.parts[0].copy_with(weight: 433), input.parts[1], input.parts[2].copy_with(weight: 234)]
      store.update_expense(household.anna, expense_id, input)

      field_changes(expense_id)["Aufteilung"].new.should contain "Anna 3,46 €"
    end

    it "summarizes the weights in the foreign currency when the euro shares do not tell them apart" do
      Store.weight_summary(Domain::SplitMode::Amount, "USD", [Domain::Share.new(household.anna, 433)], {household.anna => "Anna"})
        .should eq "Anna 4,33 USD"
    end

    it "refuses amounts that do not add up to the amount in the foreign currency" do
      input = store.get_expense(expense_id).to_input
      input.parts = [input.parts[0].copy_with(weight: 300), input.parts[1], input.parts[2]]

      expect_raises(Domain::ValidationError, "10,00 USD") { store.update_expense(household.anna, expense_id, input) }
    end

    it "refuses a rate that converts the amount to 0 €" do
      input = store.get_expense(expense_id).to_input
      input.fx_rate = 1e9

      expect_raises(Domain::ValidationError, "0 €") { store.update_expense(household.anna, expense_id, input) }
    end
  end

  describe "changes of only the rate, the rate source or the weights" do
    expense_id = 0_i64
    input = Store::ExpenseInput.new

    before_each do
      input = household.foreign("Diner", 1000, "USD", 1.25, "2026-08-01", household.ben, household.anna, household.ben)
      input.split_mode = Domain::SplitMode::Shares
      input.parts = [Domain::Part.new(household.anna, 1), Domain::Part.new(household.ben, 1)]
      expense_id = store.create_expense(household.ben, input)
    end

    it "stores and logs a changed rate that leaves the euro cents as they are" do
      input.fx_rate = 1.2501
      store.update_expense(household.anna, expense_id, input)

      store.get_expense(expense_id).fx_rate.should eq 1.2501
      change = field_changes(expense_id)["Kurs"]
      {change.old, change.new}.should eq({"1 € = 1,25 USD (EZB)", "1 € = 1,2501 USD (EZB)"})
    end

    it "stores and logs a changed rate source" do
      input.fx_source = Domain::FXSource::Manual
      store.update_expense(household.anna, expense_id, input)

      store.get_expense(expense_id).fx_source.should eq Domain::FXSource::Manual
      field_changes(expense_id)["Kurs"].new.should eq "1 € = 1,25 USD (manuell)"
    end

    it "stores and logs changed weights that leave the euro cents as they are" do
      input.parts = [Domain::Part.new(household.anna, 2), Domain::Part.new(household.ben, 2)]
      store.update_expense(household.anna, expense_id, input)

      store.get_expense(expense_id).parts[0].weight.should eq 2
      change = field_changes(expense_id)["Anteile"]
      {change.old, change.new}.should eq({"Anna 1, Ben 1", "Anna 2, Ben 2"})
    end
  end
end
