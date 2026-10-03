require "../spec_helper"

private def stat_string(rows : Array(Store::StatRow)) : String
  rows.join { |r| "#{r.category}#{r.title}|#{r.period}|#{r.person}|#{r.count}|#{r.amount_cents}|#{r.paid_cents || 0};" }
end

describe "Store statistics" do
  use_household

  it "summarizes the data" do
    h = household
    o = store.overview
    {o.expenses, o.reimbursements, o.first_date, o.last_date}.should eq({0, 0, nil, nil})
    h.create(h.equal("Rewe", 3000, "2026-08-15", h.anna, h.anna, h.ben))
    input = h.equal("Lidl", 500, "2026-09-11", h.anna, h.anna)
    input.category_id = nil
    h.create(input)
    h.create(Store::ExpenseInput.new(title: "Ausgleich", date: date("2026-09-13"), paid_by: h.ben, amount_cents: 777,
      reimbursement: true, parts: [Domain::Part.new(h.anna)]))
    o = store.overview
    {o.expenses, o.reimbursements, o.without_category}.should eq({2, 1, 1})
    {o.first_date, o.last_date}.should eq({date("2026-08-15"), date("2026-09-13")})
    o.activity_actions.should eq(%w(expense_created settings_updated))
  end

  it "sums up statistics" do
    h = household
    rest = store.list_categories[1].id
    h.create(h.equal("Rewe", 3000, "2026-08-15", h.anna, h.anna, h.ben, h.cleo))
    h.create(h.equal("Edeka", 1000, "2026-09-01", h.ben, h.anna, h.ben))
    input = h.equal("Pizza", 4000, "2026-09-10", h.cleo, h.ben, h.cleo)
    input.category_id = rest
    h.create(input)
    input = h.equal("Uncategorized", 500, "2026-09-11", h.anna, h.anna)
    input.category_id = nil
    h.create(input)
    deleted = h.create(h.equal("Deleted", 9999, "2026-09-12", h.anna, h.anna))
    store.delete_expense(h.anna, deleted)
    h.create(Store::ExpenseInput.new(title: "Reimbursement", date: date("2026-09-13"), paid_by: h.ben,
      amount_cents: 777, reimbursement: true, parts: [Domain::Part.new(h.anna)]))

    [
      {Store::StatsFilter.new(group_by: Store::StatsGroup::Category), "Lebensmittel|||2|4000|0;Restaurant|||1|4000|0;|||1|500|0;"},
      {Store::StatsFilter.new(group_by: Store::StatsGroup::Month), "|2026-08||1|3000|0;|2026-09||3|5500|0;"},
      {Store::StatsFilter.new(group_by: Store::StatsGroup::CategoryMonth, from: date("2026-09-01")), "Restaurant|2026-09||1|4000|0;Lebensmittel|2026-09||1|1000|0;|2026-09||1|500|0;"},
      {Store::StatsFilter.new(group_by: Store::StatsGroup::Category, participant_id: h.ben), "Restaurant|||1|2000|0;Lebensmittel|||2|1500|0;"},
      {Store::StatsFilter.new(group_by: Store::StatsGroup::Month, participant_id: h.anna, to: date("2026-08-31")), "|2026-08||1|1000|0;"},
      {Store::StatsFilter.new(group_by: Store::StatsGroup::Person), "||Ben|3|3500|1000;||Cleo|2|3000|4000;||Anna|3|2000|3500;"},
      {Store::StatsFilter.new(group_by: Store::StatsGroup::Person, from: date("2026-09-01"), participant_id: h.anna), "||Anna|2|1000|500;"},
      {Store::StatsFilter.new(group_by: Store::StatsGroup::Category, without_category: true), "|||1|500|0;"},
      {Store::StatsFilter.new(group_by: Store::StatsGroup::Month, category_id: h.food), "|2026-08||1|3000|0;|2026-09||1|1000|0;"},
      {Store::StatsFilter.new(group_by: Store::StatsGroup::Person, category_id: rest), "||Ben|1|2000|0;||Cleo|1|2000|4000;"},
      {Store::StatsFilter.new(group_by: Store::StatsGroup::Person, without_category: true), "||Anna|1|500|500;"},
      {Store::StatsFilter.new(group_by: Store::StatsGroup::Year), "|2026||4|8500|0;"},
      {Store::StatsFilter.new(group_by: Store::StatsGroup::Week), "|2026-W33||1|3000|0;|2026-W36||1|1000|0;|2026-W37||2|4500|0;"},
      {Store::StatsFilter.new(group_by: Store::StatsGroup::Title, any_text: ["pizza", "REWE"]), "Pizza|||1|4000|0;Rewe|||1|3000|0;"},
      {Store::StatsFilter.new(group_by: Store::StatsGroup::Month, any_text: ["edeka"]), "|2026-09||1|1000|0;"},
    ].each do |filter, want|
      stat_string(store.stats(filter)).should eq(want), failure_message: "#{filter}: got #{stat_string(store.stats(filter))}"
    end
  end

  it "groups titles regardless of case" do
    h = household
    h.create(h.equal("Rewe", 3000, "2026-08-15", h.anna, h.anna))
    h.create(h.equal("REWE", 1000, "2026-08-16", h.anna, h.anna))
    h.create(h.equal("Lidl", 500, "2026-08-17", h.anna, h.anna))
    rows = store.stats(Store::StatsFilter.new(group_by: Store::StatsGroup::Title))
    rows.size.should eq(2)
    rows[0].title.should eq("Rewe") # binary max: "Rewe" > "REWE"
    {rows[0].count, rows[0].amount_cents}.should eq({2, 4000})
  end

  it "fills empty periods" do
    periods = ->(rows : Array(Store::StatRow)) { rows.join(",") { |r| "#{r.period}=#{r.amount_cents}" } }
    rows = [Store::StatRow.new(period: "2026-01", amount_cents: 1), Store::StatRow.new(period: "2026-04", amount_cents: 4)]
    periods.call(Store.fill_periods(rows, Store::StatsGroup::Month, date("2025-12-20"), date("2026-04-02")))
      .should eq("2025-12=0,2026-01=1,2026-02=0,2026-03=0,2026-04=4")
    rows = [Store::StatRow.new(period: "2025-W52", amount_cents: 1)]
    periods.call(Store.fill_periods(rows, Store::StatsGroup::Week, date("2025-12-24"), date("2026-01-07")))
      .should eq("2025-W52=1,2026-W01=0,2026-W02=0")
    periods.call(Store.fill_periods(Array(Store::StatRow).new, Store::StatsGroup::Year, date("2024-06-01"), date("2026-01-01")))
      .should eq("2024=0,2025=0,2026=0")
    Store.fill_periods(rows, Store::StatsGroup::Category, date("2024-06-01"), date("2026-01-01")).size.should eq(1)
    # Rows outside the range stay, in period order.
    rows = [Store::StatRow.new(period: "2025-01", amount_cents: 1), Store::StatRow.new(period: "2026-05", amount_cents: 5)]
    periods.call(Store.fill_periods(rows, Store::StatsGroup::Month, date("2026-02-10"), date("2026-03-01")))
      .should eq("2025-01=1,2026-02=0,2026-03=0,2026-05=5")
    Store.fill_periods(rows, Store::StatsGroup::Month, date("2026-03-01"), date("2026-02-01")).should eq(rows)
  end
end
