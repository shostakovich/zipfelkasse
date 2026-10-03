require "../spec_helper"

private def weights(expense : Store::Expense) : Array(Int64)
  expense.parts.map(&.weight)
end

private def field_changes(store : Store, expense_id : Int64) : Hash(String, Store::FieldChange)
  activities = store.list_activity(Store::ActivityFilter.new(expense_id: expense_id, limit: 1))
  return {} of String => Store::FieldChange unless activities.size == 1 && activities[0].action == Store::Action::ExpenseUpdated
  activities[0].details.changes.to_h { |change| {change.field, change} }
end

describe "Store expenses in a foreign currency" do
  use_household

  it "stores a foreign currency" do
    h = household
    input = h.equal("Diner NYC", Domain.to_eur_cents(10000, "USD", 1.0823), "2026-08-01", h.ben, h.anna, h.ben)
    input.original_currency, input.original_amount_minor, input.fx_rate, input.fx_source = "usd", 10000_i64, 1.0823, Domain::FXSource::Ecb
    e = store.get_expense(store.create_expense(h.ben, input))
    {e.foreign?, e.original_currency, e.amount_cents, e.fx_rate, e.fx_source}.should eq({true, "USD", 9240, 1.0823, Domain::FXSource::Ecb})
  end

  # Amount, original amount and rate always fit together.
  it "derives the euro amount of a foreign currency" do
    h = household
    input = h.equal("Diner NYC", 1, "2026-08-01", h.ben, h.anna, h.ben)
    input.original_currency, input.original_amount_minor, input.fx_rate = "USD", 10000_i64, 1.0823
    id = store.create_expense(h.ben, input)
    e = store.get_expense(id)
    e.amount_cents.should eq 9240
    (e.share_of(h.anna) + e.share_of(h.ben)).should eq 9240
    input = e.to_input
    input.amount_cents = 1
    store.update_expense(h.ben, id, input)
    store.get_expense(id).amount_cents.should eq 9240
  end

  it "rotates the extra euro cent of foreign amounts with the expense ID" do
    h = household
    people = [h.anna, h.ben]
    4.times do
      input = h.equal("Taxi", 0, "2026-09-01", h.anna, h.anna, h.ben)
      # 10,00 USD at 0,999 = 10,01 €, split 5,00 USD : 5,00 USD.
      input.original_currency, input.original_amount_minor, input.fx_rate = "USD", 1000_i64, 0.999
      input.split_mode = Domain::SplitMode::Amount
      input.parts = [Domain::Part.new(h.anna, 500), Domain::Part.new(h.ben, 500)]
      id = store.create_expense(h.anna, input)
      e = store.get_expense(id)
      e.amount_cents.should eq 1001
      e.share_of(people[id % 2]).should eq 501
    end
  end

  # The weights are amounts in the foreign currency, stored as entered; the
  # euro cents are distributed in proportion to them.
  it "splits foreign currencies by amounts" do
    h = household
    input = h.equal("Hotel", 0, "2026-08-01", h.anna, h.anna, h.ben, h.cleo)
    input.original_currency, input.original_amount_minor, input.fx_rate = "USD", 1000_i64, 1.1
    input.split_mode = Domain::SplitMode::Amount
    input.parts = [Domain::Part.new(h.cleo, 334), Domain::Part.new(h.anna, 333), Domain::Part.new(h.ben, 333)]
    id = store.create_expense(h.anna, input)
    e = store.get_expense(id)
    e.amount_cents.should eq 909
    (e.share_of(h.anna) + e.share_of(h.ben) + e.share_of(h.cleo)).should eq 909
    e.share_of(h.cleo).should eq 303
    weights(e).should eq [333, 333, 334]

    # The stored input round-trips: saving it unchanged logs nothing.
    acts = store.list_activity
    store.update_expense(h.anna, id, e.to_input)
    store.list_activity.size.should eq acts.size

    # A new rate: same weights, new euro shares.
    input = e.to_input
    input.fx_rate = 1.25
    store.update_expense(h.anna, id, input)
    e = store.get_expense(id)
    {e.amount_cents, e.share_of(h.cleo), e.parts[2].weight}.should eq({800, 267, 334})

    input.parts = [input.parts[0].copy_with(weight: 433), input.parts[1], input.parts[2].copy_with(weight: 234)]
    store.update_expense(h.anna, id, input)
    acts = store.list_activity(Store::ActivityFilter.new(expense_id: id, limit: 1))
    acts[0].details.changes.map { |c| "#{c.field}: #{c.old} → #{c.new}" }.join("\n").should contain "Anna 3,46 €"
    # If only the amounts in USD change, not the euro shares, the history
    # lists the amounts in USD.
    Store.weight_summary(Domain::SplitMode::Amount, "USD", [Domain::Share.new(h.anna, 433)], {h.anna => "Anna"})
      .should eq "Anna 4,33 USD"

    # The amounts must add up to the amount in USD.
    input.parts = [input.parts[0].copy_with(weight: 300), input.parts[1], input.parts[2]]
    expect_raises(Domain::ValidationError, "10,00 USD") { store.update_expense(h.anna, id, input) }
    # Converted to 0 €.
    input.parts = [input.parts[0].copy_with(weight: 433), input.parts[1], input.parts[2]]
    input.fx_rate = 1e9
    expect_raises(Domain::ValidationError, "0 €") { store.update_expense(h.anna, id, input) }
  end

  # Changes only to rate, rate source or weights (with the same cents) are
  # stored and logged.
  it "updates rate, rate source and weights" do
    h = household
    input = h.equal("Diner", Domain.to_eur_cents(1000, "USD", 1.25), "2026-08-01", h.ben, h.anna, h.ben)
    input.original_currency, input.original_amount_minor, input.fx_rate, input.fx_source = "USD", 1000_i64, 1.25, Domain::FXSource::Ecb
    input.split_mode = Domain::SplitMode::Shares
    input.parts = [Domain::Part.new(h.anna, 1), Domain::Part.new(h.ben, 1)]
    id = store.create_expense(h.ben, input)

    input.fx_rate = 1.2501 # same euro cents
    store.update_expense(h.anna, id, input)
    store.get_expense(id).fx_rate.should eq 1.2501
    c = field_changes(store, id)["Kurs"]
    {c.old, c.new}.should eq({"1 € = 1,25 USD (EZB)", "1 € = 1,2501 USD (EZB)"})

    input.fx_source = Domain::FXSource::Manual
    store.update_expense(h.anna, id, input)
    store.get_expense(id).fx_source.should eq Domain::FXSource::Manual
    field_changes(store, id)["Kurs"].new.should eq "1 € = 1,2501 USD (manuell)"

    input.parts = [Domain::Part.new(h.anna, 2), Domain::Part.new(h.ben, 2)]
    store.update_expense(h.anna, id, input)
    store.get_expense(id).parts[0].weight.should eq 2
    c = field_changes(store, id)["Anteile"]
    {c.old, c.new}.should eq({"Anna 1, Ben 1", "Anna 2, Ben 2"})
  end
end
