require "../spec_helper"

# One string per row: "<category or title>|<period>|<person>|<count>|<amount>|<paid>;"
private def rows_text(rows : Array(Store::StatRow)) : String
  rows.join { |row| "#{row.category}#{row.title}|#{row.period}|#{row.person}|#{row.count}|#{row.amount_cents}|#{row.paid_cents || 0};" }
end

private def periods_text(rows : Array(Store::StatRow)) : String
  rows.join(",") { |row| "#{row.period}=#{row.amount_cents}" }
end

private def row(period : String, cents : Int64) : Store::StatRow
  Store::StatRow.new(period: period, amount_cents: cents)
end

describe "Store statistics" do
  use_household

  describe "the overview" do
    it "is empty without expenses" do
      overview = store.overview

      {overview.expenses, overview.reimbursements, overview.first_date, overview.last_date}.should eq({0, 0, nil, nil})
    end

    it "counts expenses and reimbursements and names the dates and the kinds of activity" do
      household.create(household.equal("Rewe", 3000, "2026-08-15", household.anna, household.anna, household.ben))
      uncategorized = household.equal("Lidl", 500, "2026-09-11", household.anna, household.anna)
      uncategorized.category_id = nil
      household.create(uncategorized)
      household.create(household.reimbursement(777, "2026-09-13", household.ben, household.anna))

      overview = store.overview

      {overview.expenses, overview.reimbursements, overview.without_category}.should eq({2, 1, 1})
      {overview.first_date, overview.last_date}.should eq({date("2026-08-15"), date("2026-09-13")})
      overview.activity_actions.should eq %w(expense_created settings_updated)
    end
  end

  describe "grouped sums" do
    before_each do
      h = household
      h.create(h.equal("Rewe", 3000, "2026-08-15", h.anna, h.anna, h.ben, h.cleo))
      h.create(h.equal("Edeka", 1000, "2026-09-01", h.ben, h.anna, h.ben))
      pizza = h.equal("Pizza", 4000, "2026-09-10", h.cleo, h.ben, h.cleo)
      pizza.category_id = h.restaurant
      h.create(pizza)
      uncategorized = h.equal("Uncategorized", 500, "2026-09-11", h.anna, h.anna)
      uncategorized.category_id = nil
      h.create(uncategorized)
      h.store.delete_expense(h.anna, h.create(h.equal("Deleted", 9999, "2026-09-12", h.anna, h.anna)))
      h.create(h.reimbursement(777, "2026-09-13", h.ben, h.anna))
    end

    # The reimbursement and the deleted expense never count.
    {
      "by category"                       => {Store::StatsFilter.new(group_by: Store::StatsGroup::Category), "Lebensmittel|||2|4000|0;Restaurant|||1|4000|0;|||1|500|0;"},
      "by month"                          => {Store::StatsFilter.new(group_by: Store::StatsGroup::Month), "|2026-08||1|3000|0;|2026-09||3|5500|0;"},
      "by year"                           => {Store::StatsFilter.new(group_by: Store::StatsGroup::Year), "|2026||4|8500|0;"},
      "by ISO week"                       => {Store::StatsFilter.new(group_by: Store::StatsGroup::Week), "|2026-W33||1|3000|0;|2026-W36||1|1000|0;|2026-W37||2|4500|0;"},
      "by category and month from a date" => {Store::StatsFilter.new(group_by: Store::StatsGroup::CategoryMonth, from: date("2026-09-01")), "Restaurant|2026-09||1|4000|0;Lebensmittel|2026-09||1|1000|0;|2026-09||1|500|0;"},
      "by person with what they paid"     => {Store::StatsFilter.new(group_by: Store::StatsGroup::Person), "||Ben|3|3500|1000;||Cleo|2|3000|4000;||Anna|3|2000|3500;"},
      "by title for any of several texts" => {Store::StatsFilter.new(group_by: Store::StatsGroup::Title, any_text: ["pizza", "REWE"]), "Pizza|||1|4000|0;Rewe|||1|3000|0;"},
      "by month for one text"             => {Store::StatsFilter.new(group_by: Store::StatsGroup::Month, any_text: ["edeka"]), "|2026-09||1|1000|0;"},
      "by category without a category"    => {Store::StatsFilter.new(group_by: Store::StatsGroup::Category, without_category: true), "|||1|500|0;"},
      "by person without a category"      => {Store::StatsFilter.new(group_by: Store::StatsGroup::Person, without_category: true), "||Anna|1|500|500;"},
    }.each do |name, (filter, rows)|
      it "sums #{name}" do
        rows_text(store.stats(filter)).should eq rows
      end
    end

    it "sums only the shares of a person" do
      filter = Store::StatsFilter.new(group_by: Store::StatsGroup::Category, participant_id: household.ben)

      rows_text(store.stats(filter)).should eq "Restaurant|||1|2000|0;Lebensmittel|||2|1500|0;"
    end

    it "sums the shares of a person up to a date" do
      filter = Store::StatsFilter.new(group_by: Store::StatsGroup::Month, participant_id: household.anna, to: date("2026-08-31"))

      rows_text(store.stats(filter)).should eq "|2026-08||1|1000|0;"
    end

    it "sums a person's shares and payments from a date on" do
      filter = Store::StatsFilter.new(group_by: Store::StatsGroup::Person, from: date("2026-09-01"), participant_id: household.anna)

      rows_text(store.stats(filter)).should eq "||Anna|2|1000|500;"
    end

    it "sums the expenses of a category" do
      by_month = Store::StatsFilter.new(group_by: Store::StatsGroup::Month, category_id: household.food)
      by_person = Store::StatsFilter.new(group_by: Store::StatsGroup::Person, category_id: household.restaurant)

      rows_text(store.stats(by_month)).should eq "|2026-08||1|3000|0;|2026-09||1|1000|0;"
      rows_text(store.stats(by_person)).should eq "||Ben|1|2000|0;||Cleo|1|2000|4000;"
    end
  end

  it "groups titles regardless of case and shows the greater spelling" do
    household.create(household.equal("Rewe", 3000, "2026-08-15", household.anna, household.anna))
    household.create(household.equal("REWE", 1000, "2026-08-16", household.anna, household.anna))
    household.create(household.equal("Lidl", 500, "2026-08-17", household.anna, household.anna))

    rows = store.stats(Store::StatsFilter.new(group_by: Store::StatsGroup::Title))

    rows.size.should eq 2
    {rows[0].title, rows[0].count, rows[0].amount_cents}.should eq({"Rewe", 2, 4000})
  end

  describe ".fill_periods" do
    it "adds the months without expenses between the range's ends" do
      rows = [row("2026-01", 1), row("2026-04", 4)]

      periods_text(Store.fill_periods(rows, Store::StatsGroup::Month, date("2025-12-20"), date("2026-04-02")))
        .should eq "2025-12=0,2026-01=1,2026-02=0,2026-03=0,2026-04=4"
    end

    it "adds weeks across the turn of the year" do
      periods_text(Store.fill_periods([row("2025-W52", 1)], Store::StatsGroup::Week, date("2025-12-24"), date("2026-01-07")))
        .should eq "2025-W52=1,2026-W01=0,2026-W02=0"
    end

    it "lists the years of the range without any rows" do
      periods_text(Store.fill_periods(Array(Store::StatRow).new, Store::StatsGroup::Year, date("2024-06-01"), date("2026-01-01")))
        .should eq "2024=0,2025=0,2026=0"
    end

    it "leaves rows outside the range in place, in period order" do
      rows = [row("2025-01", 1), row("2026-05", 5)]

      periods_text(Store.fill_periods(rows, Store::StatsGroup::Month, date("2026-02-10"), date("2026-03-01")))
        .should eq "2025-01=1,2026-02=0,2026-03=0,2026-05=5"
    end

    it "leaves the rows as they are for a range that ends before it starts or for groups without periods" do
      rows = [row("2025-01", 1), row("2026-05", 5)]

      Store.fill_periods(rows, Store::StatsGroup::Month, date("2026-03-01"), date("2026-02-01")).should eq rows
      Store.fill_periods(rows, Store::StatsGroup::Category, date("2024-06-01"), date("2026-01-01")).should eq rows
    end
  end
end
