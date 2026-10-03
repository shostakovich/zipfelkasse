require "../spec_helper"

private def target(plan : String, account : String, start : String) : Store::YNABTarget
  Store::YNABTarget.new(plan_id: plan, account_id: account, start: date(start))
end

private def ynab_activity(s : Store) : Array(Store::Activity)
  s.list_activity.select { |a| a.details.text.try(&.starts_with?("YNAB")) }
end

private def settings_texts(s : Store) : Array(String)
  ynab_activity(s).map(&.details.text.to_s)
end

describe "Store YNAB" do
  use_household

  it "stores the connection" do
    h = household
    s = store
    expect_raises(Store::NotFound) { s.get_ynab_config(h.anna) }
    expect_raises(Store::NotFound) { s.set_ynab_target(h.anna, target("p", "a", "2026-09-01")) }
    s.set_ynab_token(h.anna, "tok").should be_false
    c = s.get_ynab_config(h.anna)
    {c.token, c.enabled?, c.ready?, c.start_date}.should eq({"tok", true, false, nil})
    c.inspect.should_not contain "tok\""
    c.inspect.should contain "[redacted]"
    s.set_ynab_target(h.anna, target("p", "a", "2026-09-01"))
    c = s.get_ynab_config(h.anna)
    {c.plan_id, c.account_id, c.start_date, c.ready?}.should eq({"p", "a", date("2026-09-01"), true})

    # Ben has a token, Cleo is archived, Anna disconnects later.
    s.set_ynab_token(h.ben, "tok-b")
    s.set_ynab_token(h.cleo, "tok-c")
    s.set_participant_archived(nil, h.cleo, true)
    s.list_ynab_configs.map(&.participant_id).should eq [h.anna, h.ben]
    s.set_ynab_token(h.anna, nil)
    c = s.get_ynab_config(h.anna)
    {c.token, c.enabled?, c.ready?, c.plan_id}.should eq({nil, false, false, "p"})
    s.list_ynab_configs.size.should eq 1
  end

  it "logs token and target changes" do
    h = household
    s = store
    s.set_ynab_token(h.anna, "tok")
    s.set_ynab_target(h.anna, Store::YNABTarget.new(plan_id: "p", account_id: "a", plan_name: "Haushalt",
      start: date("2026-09-01")))
    s.set_ynab_target(h.anna, Store::YNABTarget.new(plan_id: "p", account_id: "a", start: date("2026-08-01")))
    s.set_ynab_target(h.anna, Store::YNABTarget.new(plan_id: "p", account_id: "a", start: date("2026-08-01")))
    s.set_ynab_token(h.anna, "tok-2", Set{"p", "q"}).should be_false
    s.set_ynab_token(h.anna, "tok-3", Set{"q"}).should be_true
    c = s.get_ynab_config(h.anna)
    {c.plan_id, c.account_id, c.start_date}.should eq({nil, nil, date("2026-08-01")})
    s.set_ynab_token(h.anna, "")
    settings_texts(s).reverse.should eq [
      "YNAB verbunden (Token gesetzt)",
      "YNAB: Konto „a“ im Plan „Haushalt“ gewählt, Startdatum 01.09.2026",
      "YNAB: Startdatum 01.09.2026 → 01.08.2026",
      "YNAB-Token ersetzt",
      "YNAB-Token ersetzt (Plan und Konto zurückgesetzt)",
      "YNAB-Verbindung getrennt",
    ]
    ynab_activity(s).map { |a| {a.actor_id, a.action} }.uniq.should eq [{h.anna, Store::Action::SettingsUpdated}]
  end

  it "resets the sync state when the target changes" do
    h = household
    s = store
    id = s.create_expense(h.anna, h.equal("Kino", 1000, "2026-09-10", h.anna, h.anna, h.ben))
    s.set_ynab_token(h.anna, "tok")
    s.set_ynab_target(h.anna, target("p", "a", "2026-09-01"))
    at = Time.utc(2026, 9, 10, 12, 0, 0)
    s.put_ynab_sync(Store::YNABSync.new(id, h.anna, txn_id: "t1", synced_hash: "h", synced_at: at))
    rows = s.list_ynab_sync(h.anna)
    rows.size.should eq 1
    {rows[0].txn_id, rows[0].synced_at}.should eq({"t1", at})
    # Changing only the start date: sync state is kept.
    s.set_ynab_target(h.anna, target("p", "a", "2026-08-01"))
    s.list_ynab_sync(h.anna)[0].txn_id.should eq "t1"
    # Changing the account: the rows stay (the sync looks for their
    # transactions in the new account), but without the old transaction.
    s.set_ynab_target(h.anna, target("p", "b", "2026-08-01"))
    rows = s.list_ynab_sync(h.anna)
    rows.size.should eq 1
    {rows[0].txn_id, rows[0].synced_hash, rows[0].synced_at}.should eq({nil, Store::YNABSync::RETARGET, nil})
    s.ynab_sync_summary(h.anna)[0].should eq 0
  end

  it "stores the category mapping and summarises the sync" do
    h = household
    s = store
    s.set_ynab_category_map(h.anna, {h.food => "y1", 999_i64 => ""})
    expect_invalid("Unbekannte Kategorie.") do
      s.set_ynab_category_map(h.anna, {999_i64 => "y2"})
    end
    s.ynab_category_map(h.anna).should eq({h.food => "y1"})
    s.ynab_category_map(h.ben).should be_empty

    a = s.create_expense(h.anna, h.equal("A", 1000, "2026-09-10", h.anna, h.anna, h.ben))
    b = s.create_expense(h.anna, h.equal("B", 1000, "2026-09-11", h.anna, h.anna, h.ben))
    s.put_ynab_sync(Store::YNABSync.new(a, h.anna, txn_id: "t1", synced_hash: "h"),
      Store::YNABSync.new(b, h.anna, last_error: "broken"))
    synced, problems = s.ynab_sync_summary(h.anna)
    synced.should eq 1
    problems.should eq [Store::YNABSyncProblem.new(b, "B", date("2026-09-11"), "broken")]
    s.delete_ynab_sync(h.anna, a, b)
    s.list_ynab_sync(h.anna).should be_empty
  end

  it "logs changes of the category mapping" do
    h = household
    s = store
    cats = s.list_categories
    food, restaurant = cats[0], cats[1]
    names = {"y1" => "Lebensmittel & Drogerie", "y2" => "Essen gehen"}
    s.set_ynab_category_map(h.anna, {food.id => "y1"}, names)
    s.set_ynab_category_map(h.anna, {food.id => "y1"}, names)
    s.set_ynab_category_map(h.anna, {restaurant.id => "y2", food.id => "gone"}, names)
    settings_texts(s).reverse.should eq [
      "YNAB: Kategorie-Zuordnung geändert (#{food.name} → Lebensmittel & Drogerie)",
      "YNAB: Kategorie-Zuordnung geändert (#{food.name} → (nicht mehr vorhanden) (vorher Lebensmittel & Drogerie), " \
      "#{restaurant.name} → Essen gehen)",
    ]
    s.set_ynab_category_map(h.anna, {} of Int64 => String, names)
    settings_texts(s).first.should eq "YNAB: Kategorie-Zuordnung geändert (#{food.name} → unkategorisiert " \
                                      "(vorher (nicht mehr vorhanden)), #{restaurant.name} → unkategorisiert (vorher Essen gehen))"
  end

  it "records when the target was chosen" do
    h = household
    s = store
    clock = Time.utc(2026, 9, 1, 10, 0, 0)
    s.clock = -> { clock }
    s.set_ynab_token(h.anna, "tok")
    s.get_ynab_config(h.anna).connected_at.should be_nil
    s.set_ynab_target(h.anna, target("p", "a", "2026-09-01"))
    s.get_ynab_config(h.anna).connected_at.should eq clock
    # Changing only the start date: timestamp is kept.
    clock += 1.hour
    s.set_ynab_target(h.anna, target("p", "a", "2026-08-01"))
    s.get_ynab_config(h.anna).connected_at.should eq clock - 1.hour
    # Account changed: set up anew.
    s.set_ynab_target(h.anna, target("p", "b", "2026-08-01"))
    s.get_ynab_config(h.anna).connected_at.should eq clock
    list = s.list_ynab_configs
    list.size.should eq 1
    list[0].connected_at.should eq clock
    # Legacy data without a stored timestamp: set once.
    s.set_ynab_token(h.ben, "tok-b")
    s.ensure_ynab_connected_at(h.ben).should eq clock
    clock += 1.hour
    s.ensure_ynab_connected_at(h.ben).should eq clock - 1.hour
    expect_raises(Store::NotFound) { s.ensure_ynab_connected_at(h.cleo) }
  end

  it "stores the sync status" do
    h = household
    s = store
    expect_raises(Store::NotFound) { s.get_ynab_status(h.anna) }
    expect_raises(Store::NotFound) { s.set_ynab_status(h.anna, Store::YNABStatus.new(summary: "x")) }
    s.set_ynab_token(h.anna, "tok")
    s.get_ynab_status(h.anna).should eq Store::YNABStatus.new
    run = Time.utc(2026, 9, 1, 10, 0, 0, nanosecond: 123456789)
    want = Store::YNABStatus.new(last_run: run, last_sync: run - 1.hour, summary: "1 neu", error: "kaputt",
      token_invalid: true, retry_at: run + 5.minutes, backoff: 10.minutes)
    s.set_ynab_status(h.anna, want)
    s.get_ynab_status(h.anna).should eq want
    s.db.scalar("SELECT last_run || ' ' || retry_at FROM ynab_config WHERE participant_id = ?", h.anna)
      .should eq "2026-09-01T10:00:00.123456789Z 2026-09-01T10:05:00.123456789Z"
    # The target does not touch the status.
    s.set_ynab_target(h.anna, target("p", "a", "2026-09-01"))
    s.get_ynab_status(h.anna).should eq want
    # A new token resets what belonged to the old one, in the same write.
    s.set_ynab_token(h.anna, "tok-2")
    reset = Store::YNABStatus.new(last_run: want.last_run, last_sync: want.last_sync, summary: want.summary)
    s.get_ynab_status(h.anna).should eq reset
    s.set_ynab_status(h.anna, want)
    s.set_ynab_token(h.anna, "")
    s.get_ynab_status(h.anna).should eq reset
  end
end
