require "../spec_helper"

private def service : Recurring::Service
  Recurring::Service.new(household.deps)
end

private def monthly_cloud(title : String = "Cloud", on : String = "2026-01-05", cents = 9091_i64, rate = 1.1,
                          source = Domain::FXSource::Ecb) : Store::ExpenseInput
  input = expense(title, on, cents)
  input.original_currency, input.original_amount_minor, input.fx_rate, input.fx_source = "USD", 10000_i64, rate, source
  input
end

private def expense(title : String, on : String, cents : Int64) : Store::ExpenseInput
  household.equal(title, cents, on, household.anna, household.anna, household.ben)
end

# Creates the expense and makes it the template and first instance of a rule.
private def rule(input : Store::ExpenseInput, frequency : Domain::Frequency) : {Int64, Int64}
  expense_id = household.create(input)
  {store.create_recurring_from_expense(household.anna, expense_id, frequency), expense_id}
end

private def instances(rule_id : Int64) : Array(Store::Expense)
  store.list_expenses.reverse.select { |expense| expense.recurring_id == rule_id }
end

private def dates(rule_id : Int64) : String
  instances(rule_id).join(" ") { |expense| Store.format_date(expense.date) }
end

private def next_date(rule_id : Int64) : String
  Store.format_date(store.get_recurring(rule_id).next_date)
end

# Dates of all live expenses with this title, oldest first.
private def titled(title : String) : String
  store.list_expenses.reverse.select { |expense| expense.title == title }.join(" ") { |expense| Store.format_date(expense.date) }
end

private def materialize(service : Recurring::Service, today : String) : Int32
  service.materialize(date(today))
end

describe Recurring::Service do
  use_household

  before_each { household.now = Time.utc(2026, 10, 2, 12) }

  it "clamps monthly occurrences to the end of the month and returns to the anchor day" do
    service = service()
    rule_id, _ = rule(expense("Miete", "2026-01-31", 100000), Domain::Frequency::Monthly)

    materialize(service, "2026-02-27").should eq 0
    materialize(service, "2026-05-15").should eq 3
    dates(rule_id).should eq "2026-01-31 2026-02-28 2026-03-31 2026-04-30"
    next_date(rule_id).should eq "2026-05-31"
    materialize(service, "2026-05-15").should eq 0
    materialize(service, "2026-05-31").should eq 1
  end

  it "creates instances like the template, entered by the system" do
    rule_id, _ = rule(expense("Miete", "2026-01-31", 100000), Domain::Frequency::Monthly)
    materialize(service, "2026-03-01").should eq 1

    instances(rule_id).each do |instance|
      {instance.title, instance.amount_cents, instance.shares.size, instance.paid_by}.should eq({"Miete", 100000, 2, household.anna})
    end
    activity = store.list_activity(Store::ActivityFilter.new(limit: 1)).first
    {activity.action, activity.actor_id}.should eq({Store::Action::ExpenseCreated, nil})
  end

  it "moves a yearly expense of 29 February to the 28th in other years" do
    rule_id, _ = rule(expense("Versicherung", "2024-02-29", 12000), Domain::Frequency::Yearly)
    materialize(service, "2028-03-01").should eq 4
    dates(rule_id).should eq "2024-02-29 2025-02-28 2026-02-28 2027-02-28 2028-02-29"
  end

  it "catches up weekly occurrences" do
    rule_id, _ = rule(expense("Putzen", "2026-09-01", 4000), Domain::Frequency::Weekly)
    materialize(service, "2026-10-02").should eq 4
    dates(rule_id).should eq "2026-09-01 2026-09-08 2026-09-15 2026-09-22 2026-09-29"
    next_date(rule_id).should eq "2026-10-06"
  end

  it "creates no duplicates after a crash that left next_date behind" do
    rule_id, _ = rule(expense("Strom", "2026-01-15", 5000), Domain::Frequency::Monthly)
    crashed = expense("Strom", "2026-02-15", 5000)
    crashed.recurring_id = rule_id
    store.create_expense(nil, crashed)

    materialize(service, "2026-03-20").should eq 1
    dates(rule_id).should eq "2026-01-15 2026-02-15 2026-03-15"
  end

  it "creates no duplicates after a restart or a reset next_date" do
    rule_id, _ = rule(expense("Strom", "2026-01-15", 5000), Domain::Frequency::Monthly)
    materialize(service, "2026-03-20").should eq 2

    materialize(service, "2026-03-20").should eq 0
    store.set_recurring_next_date(rule_id, date("2026-04-15"), date("2026-01-15"))
    materialize(service, "2026-03-20").should eq 0
    next_date(rule_id).should eq "2026-04-15"
  end

  it "does not catch up the occurrences of a paused rule once it is resumed" do
    rule_id, _ = rule(expense("Kino", "2026-01-10", 2000), Domain::Frequency::Monthly)
    store.set_recurring_active(nil, rule_id, false, date("2026-01-20"))
    materialize(service, "2026-05-01").should eq 0

    store.set_recurring_active(nil, rule_id, true, date("2026-05-01"))
    materialize(service, "2026-05-01").should eq 0
    materialize(service, "2026-05-10").should eq 1
    dates(rule_id).should eq "2026-01-10 2026-05-10"
  end

  it "creates at most 400 occurrences per rule and run" do
    rule_id, _ = rule(expense("Putzen", "2000-01-03", 100), Domain::Frequency::Weekly)
    materialize(service, "2026-10-02").should eq 400
    next_date(rule_id).should eq Store.format_date(Domain.occurrence(Domain::Frequency::Weekly, date("2000-01-03"), 401))
    materialize(service, "2026-10-02").should eq 400
    instances(rule_id).size.should eq 801
  end

  describe "foreign currencies" do
    it "converts a foreign amount with the rate of the occurrence date" do
      rule_id, _ = rule(monthly_cloud, Domain::Frequency::Monthly)
      household.fx.rates["USD"] = 1.25

      materialize(service, "2026-02-05").should eq 1
      got = instances(rule_id)[1]
      {got.amount_cents, got.fx_rate, got.original_amount_minor, got.original_currency, got.fx_source}
        .should eq({8000, 1.25, 10000, "USD", Domain::FXSource::Ecb})
      household.fx.calls.should eq [date("2026-02-05")]
    end

    it "creates nothing while the rate is unavailable and catches up with the day's rate later" do
      service = service()
      rule_id, _ = rule(monthly_cloud, Domain::Frequency::Monthly)
      household.fx.rates["USD"] = 1.25
      household.fx.failure = Exception.new("ECB not reachable")

      error = expect_raises(Recurring::Error) { materialize(service, "2026-03-05") }
      error.created.should eq 0
      next_date(rule_id).should eq "2026-02-05"
      dates(rule_id).should eq "2026-01-05"

      household.fx.failure = nil
      materialize(service, "2026-03-05").should eq 2
      instances(rule_id).map { |expense| {expense.amount_cents, expense.fx_rate} }.last(2).should eq [{8000, 1.25}, {8000, 1.25}]
    end

    it "keeps the template's rate when no rate exists for the date" do
      rule_id, _ = rule(monthly_cloud, Domain::Frequency::Monthly)

      materialize(service, "2026-02-05").should eq 1
      got = instances(rule_id)[1]
      {got.amount_cents, got.fx_rate}.should eq({9091, 1.1})
      next_date(rule_id).should eq "2026-03-05"
    end

    it "does not carry over a manual template rate" do
      rule_id, _ = rule(monthly_cloud(cents: 0, rate: 1.3, source: Domain::FXSource::Manual), Domain::Frequency::Monthly)
      {instances(rule_id)[0].amount_cents, instances(rule_id)[0].fx_rate}.should eq({7692, 1.3})
      household.fx.rates["USD"] = 1.25

      materialize(service, "2026-02-05").should eq 1
      got = instances(rule_id)[1]
      {got.amount_cents, got.fx_rate, got.fx_source}.should eq({8000, 1.25, Domain::FXSource::Ecb})
    end

    it "keeps fixed amounts in the foreign currency and converts the shares" do
      input = monthly_cloud("Hotel", cents: 0)
      input.split_mode = Domain::SplitMode::Amount
      input.parts = [Domain::Part.new(household.anna, 6000), Domain::Part.new(household.ben, 4000)]
      rule_id, _ = rule(input, Domain::Frequency::Monthly)
      household.fx.rates["USD"] = 1.25

      materialize(service, "2026-02-05").should eq 1
      got = instances(rule_id)[1]
      {got.amount_cents, got.share_of(household.anna), got.share_of(household.ben)}.should eq({8000, 4800, 3200})
      got.parts.map(&.weight).should eq [6000, 4000]
    end
  end

  describe "a rule changed during its catch-up" do
    {
      "paused" => {"2026-01-05 2026-02-05", "2026-03-05", ->(rule_id : Int64) {
        store.set_recurring_active(nil, rule_id, false, date("2026-05-10"))
      }},
      "paused and resumed" => {"2026-01-05 2026-02-05 2026-03-05", "2026-06-05", ->(rule_id : Int64) {
        store.set_recurring_active(nil, rule_id, false, date("2026-05-10"))
        store.set_recurring_active(nil, rule_id, true, date("2026-05-10"))
      }},
    }.each do |name, (created, next_date, change)|
      it "stops without an error when it is #{name}" do
        household.fx.rates["USD"] = 1.25
        rule_id, _ = rule(monthly_cloud, Domain::Frequency::Monthly)
        household.fx.on_call = -> { change.call(rule_id) if household.fx.calls.size == 2 }

        materialize(service, "2026-05-10")
        dates(rule_id).should eq created
        next_date(rule_id).should eq next_date
      end
    end

    it "stops without an error when it is deleted" do
      household.fx.rates["USD"] = 1.25
      rule_id, _ = rule(monthly_cloud, Domain::Frequency::Monthly)
      household.fx.on_call = -> { store.delete_recurring(household.anna, rule_id) if household.fx.calls.size == 2 }

      materialize(service, "2026-05-10").should eq 1
      titled("Cloud").should eq "2026-01-05 2026-02-05"
    end
  end

  describe "occurrences for which an equal expense exists" do
    it "skips an occurrence for which an equal expense was entered, and no other" do
      rule_id, _ = rule(expense("Miete", "2026-01-31", 100000), Domain::Frequency::Monthly)
      equal = expense("Miete", "2026-02-28", 100000)
      other_amount = expense("Miete", "2026-03-31", 99999)
      other_title = expense("Mieten", "2026-03-31", 100000)
      other_payer = expense("Miete", "2026-03-31", 100000)
      other_payer.paid_by = household.ben
      deleted = household.create(expense("Miete", "2026-04-30", 100000))
      [equal, other_amount, other_title, other_payer].each { |input| household.create(input) }
      store.delete_expense(household.anna, deleted)

      materialize(service, "2026-05-15").should eq 2

      dates(rule_id).should eq "2026-01-31 2026-03-31 2026-04-30"
      next_date(rule_id).should eq "2026-05-31"
    end

    it "matches foreign expenses by original amount and currency" do
      household.fx.rates["USD"] = 1.25
      input = monthly_cloud
      rule_id, _ = rule(input, Domain::Frequency::Monthly)
      equal = input
      equal.date, equal.amount_cents, equal.fx_rate = date("2026-02-05"), 9000_i64, 1.111
      household.create(equal)

      materialize(service, "2026-03-05").should eq 1
      dates(rule_id).should eq "2026-01-05 2026-03-05"
      household.fx.calls.should eq [date("2026-03-05")]
    end

    it "skips the occurrences of a deleted rule when the expense becomes a rule again" do
      rule_id, expense_id = rule(expense("Miete", "2026-01-31", 100000), Domain::Frequency::Monthly)
      materialize(service, "2026-05-15").should eq 3
      store.delete_recurring(household.anna, rule_id)

      preview = service.previews(store.get_expense(expense_id)).find!(&.frequency.monthly?)
      {preview.missed, preview.existing}.should eq({8, 3})

      new_rule = store.create_recurring_from_expense(household.anna, expense_id, Domain::Frequency::Monthly)
      service.materialize_rule(new_rule, date("2026-10-02")).should eq 5
      titled("Miete").should eq "2026-01-31 2026-02-28 2026-03-31 2026-04-30 2026-05-31 2026-06-30 2026-07-31 2026-08-31 2026-09-30"
    end
  end

  describe "#materialize_rule" do
    it "creates only the occurrences of its own rule" do
      other, _ = rule(expense("Strom", "2026-08-02", 5000), Domain::Frequency::Monthly)
      _, rent = rule(expense("Miete", "2026-08-31", 100000), Domain::Frequency::Monthly)
      rent_rule = store.get_expense(rent).recurring_id.not_nil!

      service.materialize_rule(rent_rule, date("2026-10-02")).should eq 1
      dates(other).should eq "2026-08-02"
      titled("Miete").should eq "2026-08-31 2026-09-30"
    end

    it "creates the occurrence of the day a paused rule is resumed" do
      rule_id, _ = rule(expense("Putzen", "2026-09-25", 4000), Domain::Frequency::Weekly)
      store.set_recurring_active(nil, rule_id, false, date("2026-09-26"))
      store.set_recurring_active(nil, rule_id, true, date("2026-10-02"))

      service.materialize_rule(rule_id, date("2026-10-02")).should eq 1
      dates(rule_id).should eq "2026-09-25 2026-10-02"
    end
  end

  describe "#run" do
    it "starts a run at a fixed interval, not an interval after each run" do
      rule(monthly_cloud(on: "2026-08-20"), Domain::Frequency::Monthly)
      starts = [] of Time::Instant
      household.fx.on_call = -> { starts << Time.instant; sleep 150.milliseconds }
      household.fx.failure = Exception.new("ECB not reachable")
      stopper = Stopper.new
      stopped = Channel(Nil).new
      spawn do
        service.run(stopper, every: 200.milliseconds)
        stopped.close
      end

      deadline = Time.instant + 2.seconds
      while starts.size < 2 && Time.instant < deadline
        sleep 5.milliseconds
      end
      stopper.stop
      stopped.receive?

      starts.size.should be >= 2
      (starts[1] - starts[0]).should be < 275.milliseconds
    end
  end
end

describe Recurring::FreqOption do
  later = "eingetragen – die ersten 400 Termine sofort, der Rest in den nächsten Stunden"

  {
    {0, 0}    => "",
    {1, 0}    => "1 verpasster Termin wird sofort eingetragen",
    {4, 1}    => "3 verpasste Termine werden sofort eingetragen; 1 bereits als Ausgabe vorhandener Termin wird übersprungen",
    {2, 2}    => "2 bereits als Ausgabe vorhandene Termine werden übersprungen",
    {400, 0}  => "400 verpasste Termine werden sofort eingetragen",
    {610, 10} => "600 verpasste Termine werden #{later}; 10 bereits als Ausgabe vorhandene Termine werden übersprungen",
    {1001, 0} => "mehr als 1000 verpasste Termine werden #{later}",
    {1001, 3} => "mehr als 1000 verpasste Termine werden #{later}; mindestens 3 bereits als Ausgabe vorhandene Termine werden übersprungen",
  }.each do |(missed, existing), note|
    it "describes #{missed} missed occurrences of which #{existing} exist" do
      preview = Recurring::Preview.new(Domain::Frequency::Monthly, date("2026-01-01"), missed, existing)
      Recurring::FreqOption.new(preview, false).note.should eq note
    end
  end
end
