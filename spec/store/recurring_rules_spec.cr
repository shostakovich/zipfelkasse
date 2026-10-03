require "../spec_helper"

private def instance_of(rule_id : Int64, title : String, on : String, payer : Int64 = household.anna) : Store::ExpenseInput
  input = household.equal(title, 2000, on, payer, household.anna, household.ben)
  input.recurring_id = rule_id
  input
end

describe "Store recurring expenses" do
  use_household

  describe "creating a rule from an expense" do
    expense_id = 0_i64
    rule_id = 0_i64
    input = Store::ExpenseInput.new

    before_each do
      input = household.equal("Miete", 100000, "2026-01-31", household.anna, household.anna, household.ben)
      input.notes = "Januar"
      expense_id = household.create(input)
      rule_id = store.create_recurring_from_expense(household.anna, expense_id, Domain::Frequency::Monthly)
    end

    it "starts at the date of the expense and continues with the next occurrence" do
      rule = store.get_recurring(rule_id)

      {rule.start_date, rule.next_date, rule.active?, rule.created_by, rule.frequency}
        .should eq({date("2026-01-31"), date("2026-02-28"), true, household.anna, Domain::Frequency::Monthly})
    end

    it "keeps the expense as the template, without its date" do
      template = store.get_recurring(rule_id).template

      {template.title, template.amount_cents, template.notes, template.parts.size, template.date, template.recurring_id, template.original_currency}
        .should eq({"Miete", 100000, "Januar", 2, nil, nil, "EUR"})
      JSON.parse(store.db.scalar("SELECT template_json FROM recurring WHERE id = ?", rule_id).as(String)).as_h.keys.should_not contain "date"
    end

    it "makes the expense the first instance of the rule" do
      store.get_expense(expense_id).recurring_id.should eq rule_id

      input.recurring_id = rule_id
      expect_raises(Store::RecurringExists) { store.create_expense(nil, input) }
    end

    it "refuses a second rule for the same expense" do
      expect_invalid("Diese Ausgabe gehört schon zu einer wiederkehrenden Ausgabe.") do
        store.create_recurring_from_expense(household.anna, expense_id, Domain::Frequency::Weekly)
      end
    end

    it "refuses an unknown expense" do
      expect_raises(Store::NotFound) { store.create_recurring_from_expense(household.anna, 999_i64, Domain::Frequency::Monthly) }
    end

    it "logs the new rule with the expense" do
      entry = store.list_activity(Store::ActivityFilter.new(expense_id: expense_id)).first

      {entry.action, entry.actor_id}.should eq({Store::Action::RecurringCreated, household.anna})
      entry.details.should eq Store::ActivityDetails.new(title: "Miete", amount_cents: 100000_i64, text: "„Miete“ wiederholt sich jetzt monatlich.")
    end

    it "is due from its next date on" do
      store.due_recurring(date("2026-02-27")).should be_empty
      store.due_recurring(date("2026-02-28")).size.should eq 1
    end
  end

  describe "pausing and resuming" do
    rule_id = 0_i64

    before_each do
      expense_id = household.create(household.equal("Kino", 2000, "2026-01-05", household.anna, household.anna, household.ben))
      rule_id = store.create_recurring_from_expense(household.anna, expense_id, Domain::Frequency::Weekly)
    end

    it "makes a paused rule no longer due" do
      store.set_recurring_active(nil, rule_id, false, date("2026-01-10"))

      store.due_recurring(date("2026-03-01")).should be_empty
    end

    it "continues with the next occurrence after the resume day, without catching up" do
      store.set_recurring_active(nil, rule_id, false, date("2026-01-10"))
      store.set_recurring_active(nil, rule_id, true, date("2026-03-04")) # a Wednesday

      rule = store.get_recurring(rule_id)
      {rule.active?, rule.next_date}.should eq({true, date("2026-03-09")})
    end

    it "counts the occurrence of the resume day itself" do
      store.set_recurring_active(nil, rule_id, false, date("2026-03-05"))
      store.set_recurring_active(nil, rule_id, true, date("2026-03-16"))

      store.get_recurring(rule_id).next_date.should eq date("2026-03-16")
    end

    it "logs both changes" do
      store.set_recurring_active(nil, rule_id, false, date("2026-01-10"))
      store.set_recurring_active(nil, rule_id, true, date("2026-03-04"))

      store.list_activity.first(2).map(&.details.text).should eq [
        "Wiederholung „Kino“ (wöchentlich) fortgesetzt",
        "Wiederholung „Kino“ (wöchentlich) pausiert",
      ]
    end

    it "refuses an unknown rule" do
      expect_raises(Store::NotFound) { store.set_recurring_active(nil, 999_i64, true, date("2026-03-16")) }
    end

    it "advances next_date only from the value the caller expects" do
      expect_raises(Store::RecurringChanged) { store.set_recurring_next_date(rule_id, date("2026-03-09"), date("2026-03-23")) }

      store.set_recurring_next_date(rule_id, date("2026-01-12"), date("2026-03-23"))
      store.list_recurring.map(&.next_date).should eq [date("2026-03-23")]
    end

    it "neither advances nor gets instances while it is paused" do
      store.set_recurring_active(nil, rule_id, false, date("2026-03-23"))

      expect_raises(Store::RecurringChanged) { store.set_recurring_next_date(rule_id, date("2026-03-23"), date("2026-03-30")) }
      expect_raises(Store::RecurringChanged) { store.create_expense(nil, instance_of(rule_id, "Kino", "2026-03-23")) }
    end
  end

  describe "deleting a rule" do
    expense_id = 0_i64
    rule_id = 0_i64

    before_each do
      expense_id = household.create(household.equal("Kino", 2000, "2026-01-05", household.anna, household.anna, household.ben))
      rule_id = store.create_recurring_from_expense(household.anna, expense_id, Domain::Frequency::Weekly)
      store.delete_recurring(household.ben, rule_id)
    end

    it "logs the end of the rule" do
      entry = store.list_activity.first

      {entry.action, entry.actor_id, entry.expense_id}.should eq({Store::Action::RecurringDeleted, household.ben, nil})
      entry.details.should eq Store::ActivityDetails.new(title: "Kino", amount_cents: 2000_i64, text: "Wiederholung von „Kino“ beendet.")
    end

    it "keeps the created expenses and detaches them from the rule" do
      expense = store.get_expense(expense_id)

      {expense.deleted?, expense.recurring_id}.should eq({false, nil})
    end

    it "refuses instances and a next date for the deleted rule without a foreign key error" do
      expect_raises(Store::RecurringChanged) { store.create_expense(nil, instance_of(rule_id, "Kino", "2026-03-23")) }
      expect_raises(Store::RecurringChanged) { store.set_recurring_next_date(rule_id, date("2026-03-23"), date("2026-03-30")) }
    end

    it "is gone" do
      expect_raises(Store::NotFound) { store.get_recurring(rule_id) }
      expect_raises(Store::NotFound) { store.delete_recurring(household.ben, rule_id) }
    end
  end

  describe "adopting the latest instance as the template" do
    rule_id = 0_i64
    first = 0_i64
    second = 0_i64

    before_each do
      first = household.create(household.equal("Strom", 5000, "2026-01-15", household.anna, household.anna, household.ben))
      rule_id = store.create_recurring_from_expense(household.anna, first, Domain::Frequency::Monthly)
      latest = household.equal("Strom", 6000, "2026-02-15", household.anna, household.anna, household.ben, household.cleo)
      latest.recurring_id = rule_id
      second = store.create_expense(nil, latest)
    end

    it "takes amount and split of the newest instance" do
      store.update_recurring_template_from_latest(nil, rule_id)

      template = store.get_recurring(rule_id).template
      {template.amount_cents, template.parts.size, template.date}.should eq({6000, 3, nil})
      store.list_activity.first.details.text.should eq "Wiederholung „Strom“ (monatlich): Vorlage aus der letzten Ausgabe übernommen"
    end

    it "does not count deleted instances" do
      store.delete_expense(household.anna, second)
      store.delete_expense(household.anna, first)

      expect_raises(Store::NoInstance) { store.update_recurring_template_from_latest(nil, rule_id) }
    end

    it "refuses an unknown rule" do
      expect_raises(Store::NotFound) { store.update_recurring_template_from_latest(nil, rule_id + 1000) }
    end
  end

  it "reads stored templates, also incomplete ones" do
    stored = %q({"title":"Pizza & <Wein>","category_id":1,"paid_by":1,) +
             %q("notes":"","is_reimbursement":false,"split_mode":"equal","amount_cents":2310,"parts":[{"participant_id":1,) +
             %q("weight":1},{"participant_id":2,"weight":1}],"original_amount_minor":2500,"original_currency":"USD",) +
             %q("fx_rate":1.0823,"fx_source":"ezb"})
    {stored, "{}", %({"parts":null,"fx_rate":1})}.each do |json|
      store.db.exec("INSERT INTO recurring (template_json, frequency, start_date, next_date, created_at, updated_at) " \
                    "VALUES (?, 'monthly', '2026-01-31', '2026-02-28', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')", json)
    end

    rules = store.list_recurring
    rules.map(&.created_by).should eq [nil, nil, nil]
    template = rules[0].template
    {template.title, template.date, template.parts.size, template.original_currency, template.fx_rate, template.amount_cents}
      .should eq({"Pizza & <Wein>", nil, 2, "USD", 1.0823, 2310})
    {rules[1].template.title, rules[1].template.parts}.should eq({"", [] of Domain::Part})
    {rules[2].template.parts, rules[2].template.fx_rate}.should eq({[] of Domain::Part, 1.0})
  end

  it "finds the dates of expenses like a template, ignoring other payers, amounts and currencies" do
    h = household
    h.create(h.equal("Miete", 1000, "2026-01-01", h.anna, h.anna))
    h.create(h.equal("Miete", 1000, "2026-02-01", h.ben, h.anna))
    h.create(h.equal("Miete", 1001, "2026-03-01", h.anna, h.anna))
    h.create(h.equal("Miete", 1000, "2026-05-01", h.anna, h.anna))
    usd = h.foreign("Hotel", 5000, "USD", 1.1, "2026-01-10", h.anna, h.anna)
    h.create(usd)
    usd.fx_rate, usd.date = 1.2, date("2026-01-11")
    h.create(usd)

    store.expense_dates_like(h.equal(" Miete ", 1000, "2026-01-01", h.anna, h.anna), date("2026-01-01"), date("2026-04-30"))
      .should eq Set{date("2026-01-01")}
    usd.original_currency = " usd "
    store.expense_dates_like(usd, date("2026-01-01"), date("2026-01-31")).should eq Set{date("2026-01-10"), date("2026-01-11")}
  end
end
