require "../spec_helper"

private def expense(id : Int64, d : Time, paid_by : Int64, amount : Int64, shares : Array(Domain::Share)) : Store::Expense
  build_expense(id, Store::ExpenseInput.new(date: d, paid_by: paid_by, amount_cents: amount), shares)
end

private def share(id : Int64, cents : Int64) : Domain::Share
  Domain::Share.new(participant_id: id, amount_cents: cents)
end

describe "web formatting" do
  it "labels expense and activity periods" do
    today = date("2026-10-02") # Friday
    {
      "2026-10-05" => "Bevorstehend",
      "2026-10-02" => "Diese Woche",
      "2026-09-28" => "Diese Woche", # Monday, other month
      "2026-09-27" => "Letzter Monat",
      "2026-10-01" => "Diese Woche",
      "2026-08-31" => "Früher in diesem Jahr",
      "2025-12-31" => "Letztes Jahr",
      "2024-06-01" => "Älter",
    }.each { |d, want| Web.expense_period(date(d), today).should eq want }
    today = date("2026-10-20")
    Web.expense_period(date("2026-10-05"), today).should eq "Früher in diesem Monat"
    # In January, December is last month, not last year.
    Web.expense_period(date("2025-12-15"), date("2026-01-20")).should eq "Letzter Monat"
    {
      "2026-10-20" => "Heute", "2026-10-19" => "Gestern", "2026-10-18" => "Letzte Woche", "2026-10-12" => "Letzte Woche",
      "2026-10-11" => "Früher in diesem Monat", "2026-09-30" => "Letzter Monat", "2026-01-01" => "Früher in diesem Jahr",
    }.each { |d, want| Web.activity_period(date(d), today).should eq want }
  end

  it "finds category icons by keyword" do
    {"Lebensmittel" => "cart", "Miete & Nebenkosten" => "key", "Restaurant" => "utensils",
     "Was anderes" => "tag", "Sonstiges" => "receipt"}.each do |name, want|
      Web.category_icon(name).should eq want
    end
  end

  it "prepares the rows of the expense list" do
    today = date("2026-10-02")
    names = {1_i64 => "A", 2_i64 => "B", 3_i64 => "C", 4_i64 => "D"}
    active = Set{1_i64, 2_i64, 3_i64, 4_i64}
    es = [
      expense(1, today, 1, 400, [share(1, 100), share(2, 100), share(3, 100), share(4, 100)]),
      expense(2, date("2026-09-01"), 2, 300, [share(2, 150), share(3, 150)]),
    ]
    groups = Web.group_expenses(es, today, 1, names, active)
    groups.map(&.[0]).should eq ["Diese Woche", "Letzter Monat"]
    r = groups[0][1][0]
    {r.everyone, r.involved, r.my_balance}.should eq({true, true, 300})
    r = groups[1][1][0]
    {r.everyone, r.involved, r.my_balance, r.for_names}.should eq({false, false, 0, ["B", "C"]})

    # Four shares, but one belongs to archived E and active D is missing:
    # not "für alle".
    names[5_i64] = "E"
    shares = [share(1, 100), share(2, 100), share(3, 100), share(5, 100)]
    Web.group_expenses([expense(3, today, 1, 400, shares)], today, 1, names, active)[0][1][0].everyone.should be_false
    # All active people plus archived E: the names are listed, so that E's
    # share is not hidden behind "alle".
    shares << share(4, 0)
    Web.group_expenses([expense(3, today, 1, 400, shares)], today, 1, names, active)[0][1][0].everyone.should be_false
    shares = [share(2, 100), share(3, 100), share(1, 100), share(4, 0)]
    Web.group_expenses([expense(3, today, 1, 400, shares)], today, 1, names, active)[0][1][0].everyone.should be_true
  end
end
