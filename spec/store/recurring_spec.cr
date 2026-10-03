require "./expense_fixture"

private alias Store = Zipfelkasse::Store
private alias Domain = Zipfelkasse::Domain

describe "Store recurring expenses" do
  it "creates a rule from an expense" do
    with_expense_fixture do |f|
      s = f.s
      input = f.equal("Miete", 100000, "2026-01-31", f.anna, f.anna, f.ben)
      input.notes = "Januar"
      eid = s.create_expense(f.anna, input)
      expect_raises(Store::NotFound) { s.create_recurring_from_expense(f.anna, 999_i64, Domain::Frequency::Monthly) }
      rid = s.create_recurring_from_expense(f.anna, eid, Domain::Frequency::Monthly)

      r = s.get_recurring(rid)
      r.start_date.should eq date("2026-01-31")
      r.next_date.should eq date("2026-02-28")
      r.active?.should be_true
      r.created_by.should eq f.anna
      r.frequency.should eq Domain::Frequency::Monthly
      t = r.template
      {t.title, t.amount_cents, t.notes, t.parts.size, t.date, t.recurring_id, t.original_currency}
        .should eq({"Miete", 100000, "Januar", 2, nil, nil, "EUR"})
      template_json = s.db.scalar("SELECT template_json FROM recurring WHERE id = ?", rid).as(String)
      JSON.parse(template_json).as_h.keys.should_not contain("date")

      s.get_expense(eid).recurring_id.should eq rid
      store_validation_error do
        s.create_recurring_from_expense(f.anna, eid, Domain::Frequency::Weekly)
      end.should eq "Diese Ausgabe gehört schon zu einer wiederkehrenden Ausgabe."
      acts = s.list_activity(Store::ActivityFilter.new(expense_id: eid))
      acts.size.should eq 2
      acts[0].action.should eq Store::Action::RecurringCreated
      acts[0].actor_id.should eq f.anna
      acts[0].details.should eq Store::ActivityDetails.new(title: "Miete", amount_cents: 100000_i64,
        text: "„Miete“ wiederholt sich jetzt monatlich.")

      # The original expense at the anchor counts as the first instance.
      input.recurring_id = rid
      expect_raises(Store::RecurringExists) { s.create_expense(nil, input) }

      s.due_recurring(date("2026-02-27")).should be_empty
      s.due_recurring(date("2026-02-28")).size.should eq 1
    end
  end

  it "pauses, resumes and deletes a rule" do
    with_expense_fixture do |f|
      s = f.s
      eid = s.create_expense(f.anna, f.equal("Kino", 2000, "2026-01-05", f.anna, f.anna, f.ben))
      rid = s.create_recurring_from_expense(f.anna, eid, Domain::Frequency::Weekly)
      s.set_recurring_active(nil, rid, false, date("2026-01-10"))
      s.due_recurring(date("2026-03-01")).should be_empty
      # Resuming on Wednesday, Mar 4: next occurrence Monday, Mar 9 (no catch-up).
      s.set_recurring_active(nil, rid, true, date("2026-03-04"))
      r = s.get_recurring(rid)
      r.active?.should be_true
      r.next_date.should eq date("2026-03-09")
      # Resuming exactly on an occurrence: the occurrence itself counts.
      s.set_recurring_active(nil, rid, false, date("2026-03-05"))
      s.set_recurring_active(nil, rid, true, date("2026-03-16"))
      s.get_recurring(rid).next_date.should eq date("2026-03-16")
      expect_raises(Store::NotFound) { s.set_recurring_active(nil, 999_i64, true, date("2026-03-16")) }
      s.list_activity.first(2).map(&.details.text).should eq [
        "Wiederholung „Kino“ (wöchentlich) fortgesetzt",
        "Wiederholung „Kino“ (wöchentlich) pausiert",
      ]

      # next_date only advances from the expected value.
      expect_raises(Store::RecurringChanged) do
        s.set_recurring_next_date(rid, date("2026-03-09"), date("2026-03-23"))
      end
      s.set_recurring_next_date(rid, date("2026-03-16"), date("2026-03-23"))
      list = s.list_recurring
      list.size.should eq 1
      list[0].next_date.should eq date("2026-03-23")

      # A paused rule neither advances nor gets instances.
      s.set_recurring_active(nil, rid, false, date("2026-03-23"))
      expect_raises(Store::RecurringChanged) do
        s.set_recurring_next_date(rid, date("2026-03-23"), date("2026-03-30"))
      end
      input = f.equal("Kino", 2000, "2026-03-23", f.anna, f.anna, f.ben)
      input.recurring_id = rid
      expect_raises(Store::RecurringChanged) { s.create_expense(nil, input) }
      s.set_recurring_active(nil, rid, true, date("2026-03-23"))

      s.delete_recurring(f.ben, rid)
      deleted = s.list_activity.first
      {deleted.action, deleted.actor_id, deleted.expense_id}.should eq({Store::Action::RecurringDeleted, f.ben, nil})
      deleted.details.should eq Store::ActivityDetails.new(title: "Kino", amount_cents: 2000_i64,
        text: "Wiederholung von „Kino“ beendet.")
      # A deleted rule: no foreign key error, but RecurringChanged.
      expect_raises(Store::RecurringChanged) { s.create_expense(nil, input) }
      expect_raises(Store::RecurringChanged) do
        s.set_recurring_next_date(rid, date("2026-03-23"), date("2026-03-30"))
      end
      expect_raises(Store::NotFound) { s.get_recurring(rid) }
      e = s.get_expense(eid)
      e.deleted?.should be_false
      e.recurring_id.should be_nil
      expect_raises(Store::NotFound) { s.delete_recurring(f.ben, rid) }
    end
  end

  it "adopts the latest instance as the template" do
    with_expense_fixture do |f|
      s = f.s
      eid = s.create_expense(f.anna, f.equal("Strom", 5000, "2026-01-15", f.anna, f.anna, f.ben))
      rid = s.create_recurring_from_expense(f.anna, eid, Domain::Frequency::Monthly)
      input = f.equal("Strom", 6000, "2026-02-15", f.anna, f.anna, f.ben, f.cleo)
      input.recurring_id = rid
      id2 = s.create_expense(nil, input)
      s.update_recurring_template_from_latest(nil, rid)
      t = s.get_recurring(rid).template
      {t.amount_cents, t.parts.size, t.date}.should eq({6000, 3, nil})
      s.list_activity.first.details.text.should eq "Wiederholung „Strom“ (monatlich): Vorlage aus der letzten Ausgabe übernommen"
      # Deleted instances do not count.
      s.delete_expense(f.anna, id2)
      s.delete_expense(f.anna, eid)
      expect_raises(Store::NoInstance) { s.update_recurring_template_from_latest(nil, rid) }
      expect_raises(Store::NotFound) { s.update_recurring_template_from_latest(nil, rid + 1000) }
    end
  end

  it "reads stored templates, also incomplete ones" do
    with_expense_fixture do |f|
      s = f.s
      stored = %q({"title":"Pizza & <Wein>","date":"0001-01-01T00:00:00Z","category_id":1,"paid_by":1,) +
               %q("notes":"","is_reimbursement":false,"split_mode":"equal","amount_cents":2310,"parts":[{"participant_id":1,) +
               %q("weight":1},{"participant_id":2,"weight":1}],"original_amount_minor":2500,"original_currency":"USD",) +
               %q("fx_rate":1.0823,"fx_source":"ezb","recurring_id":0})
      {stored, "{}", %({"parts":null,"fx_rate":1})}.each do |json|
        s.db.exec("INSERT INTO recurring (template_json, frequency, start_date, next_date, created_at, updated_at) " \
                  "VALUES (?, 'monthly', '2026-01-31', '2026-02-28', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')", json)
      end
      list = s.list_recurring
      list.map(&.created_by).should eq [nil, nil, nil]
      t = list[0].template
      {t.title, t.date, t.parts.size, t.original_currency, t.fx_rate, t.amount_cents}
        .should eq({"Pizza & <Wein>", nil, 2, "USD", 1.0823, 2310})
      {list[1].template.title, list[1].template.parts}.should eq({"", [] of Domain::Part})
      {list[2].template.parts, list[2].template.fx_rate}.should eq({[] of Domain::Part, 1.0})
    end
  end

  it "finds the dates of expenses like a template" do
    with_expense_fixture do |f|
      s = f.s
      s.create_expense(f.anna, f.equal("Miete", 1000, "2026-01-01", f.anna, f.anna))
      s.create_expense(f.anna, f.equal("Miete", 1000, "2026-02-01", f.ben, f.anna))
      s.create_expense(f.anna, f.equal("Miete", 1001, "2026-03-01", f.anna, f.anna))
      s.create_expense(f.anna, f.equal("Miete", 1000, "2026-05-01", f.anna, f.anna))
      usd = f.equal("Hotel", 0, "2026-01-10", f.anna, f.anna)
      usd.original_currency, usd.original_amount_minor, usd.fx_rate = "USD", 5000_i64, 1.1
      s.create_expense(f.anna, usd)
      usd.fx_rate = 1.2
      usd.date = date("2026-01-11")
      s.create_expense(f.anna, usd)

      s.expense_dates_like(f.equal(" Miete ", 1000, "2026-01-01", f.anna, f.anna), date("2026-01-01"), date("2026-04-30"))
        .should eq Set{date("2026-01-01")}
      usd.original_currency = " usd "
      s.expense_dates_like(usd, date("2026-01-01"), date("2026-01-31")).should eq Set{date("2026-01-10"), date("2026-01-11")}
    end
  end
end
