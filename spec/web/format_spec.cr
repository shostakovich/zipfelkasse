require "../spec_helper"

private def expense(id : Int64, on : Time, paid_by : Int64, cents : Int64, shares : Array(Domain::Share)) : Store::Expense
  build_expense(id, Store::ExpenseInput.new(date: on, paid_by: paid_by, amount_cents: cents), shares)
end

private def share(id : Int64, cents : Int64) : Domain::Share
  Domain::Share.new(participant_id: id, amount_cents: cents)
end

describe Web do
  describe ".period_label" do
    friday = date("2026-10-02")

    {
      "2026-10-05" => "Bevorstehend", "2026-10-02" => "Diese Woche", "2026-10-01" => "Diese Woche",
      "2026-09-28" => "Diese Woche", "2026-09-27" => "Letzter Monat", "2026-08-31" => "Früher in diesem Jahr",
      "2025-12-31" => "Letztes Jahr", "2024-06-01" => "Älter",
    }.each do |day, label|
      it "labels #{day} as #{label.inspect} on Friday, 2026-10-02" do
        Web.period_label(date(day), friday).should eq label
      end
    end

    it "labels an earlier day of the month as earlier in this month" do
      Web.period_label(date("2026-10-05"), date("2026-10-20")).should eq "Früher in diesem Monat"
    end

    it "calls December of the year before last month in January, not last year" do
      Web.period_label(date("2025-12-15"), date("2026-01-20")).should eq "Letzter Monat"
    end
  end

  describe ".period_label for the activity" do
    {
      "2026-10-20" => "Heute", "2026-10-19" => "Gestern", "2026-10-18" => "Letzte Woche", "2026-10-12" => "Letzte Woche",
      "2026-10-11" => "Früher in diesem Monat", "2026-09-30" => "Letzter Monat", "2026-01-01" => "Früher in diesem Jahr",
    }.each do |day, label|
      it "labels #{day} as #{label.inspect} on 2026-10-20" do
        Web.period_label(date(day), date("2026-10-20"), activity: true).should eq label
      end
    end
  end

  describe ".category_icon" do
    {"Lebensmittel" => "cart", "Miete & Nebenkosten" => "key", "Restaurant" => "utensils", "Was anderes" => "tag",
     "Sonstiges" => "receipt"}.each do |name, icon|
      it "picks #{icon} for the category #{name.inspect}" do
        Web.category_icon(name).should eq icon
      end
    end
  end

  describe ".group_expenses" do
    today = date("2026-10-02")
    names = {1_i64 => "A", 2_i64 => "B", 3_i64 => "C", 4_i64 => "D", 5_i64 => "E"}
    active = Set{1_i64, 2_i64, 3_i64, 4_i64}

    it "groups the expenses by period, newest first" do
      expenses = [expense(1, today, 1, 400, [share(1, 100)]), expense(2, date("2026-09-01"), 2, 300, [share(2, 150), share(3, 150)])]

      Web.group_expenses(expenses, today, 1, names, active).map(&.[0]).should eq ["Diese Woche", "Letzter Monat"]
    end

    it "marks an expense that everybody shares, from four people on, and what it means for the person" do
      shares = [share(1, 100), share(2, 100), share(3, 100), share(4, 100)]

      row = Web.group_expenses([expense(1, today, 1, 400, shares)], today, 1, names, active)[0][1][0]

      {row.everyone, row.involved, row.my_balance}.should eq({true, true, 300})
    end

    it "lists the names for an expense that the person neither paid nor shares" do
      row = Web.group_expenses([expense(2, date("2026-09-01"), 2, 300, [share(2, 150), share(3, 150)])], today, 1, names, active)[0][1][0]

      {row.everyone, row.involved, row.my_balance, row.for_names}.should eq({false, false, 0, ["B", "C"]})
    end

    it "does not say everybody when a share belongs to an archived person and an active person is missing" do
      shares = [share(1, 100), share(2, 100), share(3, 100), share(5, 100)]

      Web.group_expenses([expense(3, today, 1, 400, shares)], today, 1, names, active)[0][1][0].everyone.should be_false
    end

    it "does not say everybody when an archived person has a share besides all active people" do
      shares = [share(1, 100), share(2, 100), share(3, 100), share(4, 100), share(5, 0)]

      Web.group_expenses([expense(3, today, 1, 400, shares)], today, 1, names, active)[0][1][0].everyone.should be_false
    end

    it "says everybody for all active people, whatever the order of the shares, even with an archived share of 0" do
      shares = [share(2, 100), share(3, 100), share(1, 100), share(4, 0)]

      Web.group_expenses([expense(3, today, 1, 400, shares)], today, 1, names, active)[0][1][0].everyone.should be_true
    end
  end
end
