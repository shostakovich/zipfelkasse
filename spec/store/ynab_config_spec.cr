require "../spec_helper"

private def target(plan : String, account : String, start : String) : Store::YNABTarget
  Store::YNABTarget.new(plan_id: plan, account_id: account, start: date(start))
end

private def ynab_texts : Array(String)
  store.list_activity.compact_map(&.details.text).select(&.starts_with?("YNAB"))
end

describe "Store YNAB" do
  use_household

  describe "the connection" do
    it "does not exist before a token is stored" do
      expect_raises(Store::NotFound) { store.get_ynab_config(household.anna) }
      expect_raises(Store::NotFound) { store.set_ynab_target(household.anna, target("p", "a", "2026-09-01")) }
    end

    it "is enabled but not ready with a token alone" do
      store.set_ynab_token(household.anna, "tok").should be_false

      config = store.get_ynab_config(household.anna)
      {config.token, config.enabled?, config.ready?, config.start_date}.should eq({"tok", true, false, nil})
    end

    it "is ready with token, plan, account and start date" do
      store.set_ynab_token(household.anna, "tok")
      store.set_ynab_target(household.anna, target("p", "a", "2026-09-01"))

      config = store.get_ynab_config(household.anna)
      {config.plan_id, config.account_id, config.start_date, config.ready?}.should eq({"p", "a", date("2026-09-01"), true})
    end

    it "never shows the token when it is inspected" do
      store.set_ynab_token(household.anna, "tok")

      store.get_ynab_config(household.anna).inspect.should_not contain "tok\""
      store.get_ynab_config(household.anna).inspect.should contain "[redacted]"
    end

    it "is listed for every active person with a token" do
      store.set_ynab_token(household.anna, "tok")
      store.set_ynab_token(household.ben, "tok-b")
      store.set_ynab_token(household.cleo, "tok-c")
      store.set_participant_archived(nil, household.cleo, true)

      store.list_ynab_configs.map(&.participant_id).should eq [household.anna, household.ben]
    end

    it "keeps plan and account when the token is removed, but is no longer enabled" do
      store.set_ynab_token(household.anna, "tok")
      store.set_ynab_target(household.anna, target("p", "a", "2026-09-01"))
      store.set_ynab_token(household.anna, nil)

      config = store.get_ynab_config(household.anna)
      {config.token, config.enabled?, config.ready?, config.plan_id}.should eq({nil, false, false, "p"})
      store.list_ynab_configs.should be_empty
    end
  end

  describe "the activity log" do
    it "logs the token and the chosen target" do
      store.set_ynab_token(household.anna, "tok")
      store.set_ynab_target(household.anna, Store::YNABTarget.new(plan_id: "p", account_id: "a", plan_name: "Haushalt", start: date("2026-09-01")))
      store.set_ynab_target(household.anna, target("p", "a", "2026-08-01"))
      store.set_ynab_target(household.anna, target("p", "a", "2026-08-01"))

      ynab_texts.reverse.should eq [
        "YNAB verbunden (Token gesetzt)",
        "YNAB: Konto „a“ im Plan „Haushalt“ gewählt, Startdatum 01.09.2026",
        "YNAB: Startdatum 01.09.2026 → 01.08.2026",
      ]
    end

    it "logs a replaced token, and that plan and account were reset for another YNAB user" do
      store.set_ynab_token(household.anna, "tok")
      store.set_ynab_target(household.anna, target("p", "a", "2026-08-01"))

      store.set_ynab_token(household.anna, "tok-2", Set{"p", "q"}).should be_false
      store.set_ynab_token(household.anna, "tok-3", Set{"q"}).should be_true

      config = store.get_ynab_config(household.anna)
      {config.plan_id, config.account_id, config.start_date}.should eq({nil, nil, date("2026-08-01")})
      ynab_texts.first(2).should eq ["YNAB-Token ersetzt (Plan und Konto zurückgesetzt)", "YNAB-Token ersetzt"]
    end

    it "logs the disconnection, with the person as the author of every entry" do
      store.set_ynab_token(household.anna, "tok")
      store.set_ynab_token(household.anna, "")

      ynab_texts.first.should eq "YNAB-Verbindung getrennt"
      store.list_activity.map { |entry| {entry.actor_id, entry.action} }.uniq.should contain({household.anna, Store::Action::SettingsUpdated})
    end
  end

  describe "the sync state of expenses" do
    expense_id = 0_i64
    synced_at = Time.utc(2026, 9, 10, 12)

    before_each do
      expense_id = household.create(household.equal("Kino", 1000, "2026-09-10", household.anna, household.anna, household.ben))
      store.set_ynab_token(household.anna, "tok")
      store.set_ynab_target(household.anna, target("p", "a", "2026-09-01"))
      store.put_ynab_sync(Store::YNABSync.new(expense_id, household.anna, txn_id: "t1", synced_hash: "h", synced_at: synced_at))
    end

    it "is stored per expense" do
      rows = store.list_ynab_sync(household.anna)

      {rows.size, rows[0].txn_id, rows[0].synced_at}.should eq({1, "t1", synced_at})
    end

    it "is kept when only the start date changes" do
      store.set_ynab_target(household.anna, target("p", "a", "2026-08-01"))

      store.list_ynab_sync(household.anna)[0].txn_id.should eq "t1"
    end

    it "keeps its rows without the old transaction when the account changes, so that the sync looks for them in the new account" do
      store.set_ynab_target(household.anna, target("p", "b", "2026-08-01"))

      rows = store.list_ynab_sync(household.anna)
      {rows.size, rows[0].txn_id, rows[0].synced_hash, rows[0].synced_at}.should eq({1, nil, Store::YNABSync::RETARGET, nil})
      store.ynab_sync_summary(household.anna)[0].should eq 0
    end

    it "is summarized as the number of synced expenses and the problems of the others" do
      other = household.create(household.equal("B", 1000, "2026-09-11", household.anna, household.anna, household.ben))
      store.put_ynab_sync(Store::YNABSync.new(other, household.anna, last_error: "broken"))

      synced, problems = store.ynab_sync_summary(household.anna)

      synced.should eq 1
      problems.should eq [Store::YNABSyncProblem.new(other, "B", date("2026-09-11"), "broken")]
    end

    it "can be deleted" do
      store.delete_ynab_sync(household.anna, expense_id)

      store.list_ynab_sync(household.anna).should be_empty
    end
  end

  describe "the category mapping" do
    it "ignores an empty YNAB category and refuses an unknown app category" do
      store.set_ynab_category_map(household.anna, {household.food => "y1", 999_i64 => ""})

      expect_invalid("Unbekannte Kategorie.") { store.set_ynab_category_map(household.anna, {999_i64 => "y2"}) }
      store.ynab_category_map(household.anna).should eq({household.food => "y1"})
      store.ynab_category_map(household.ben).should be_empty
    end

    it "logs a change with the names of the YNAB categories, and nothing for an unchanged mapping" do
      names = {"y1" => "Lebensmittel & Drogerie", "y2" => "Essen gehen"}
      store.set_ynab_category_map(household.anna, {household.food => "y1"}, names)
      store.set_ynab_category_map(household.anna, {household.food => "y1"}, names)

      ynab_texts.should eq ["YNAB: Kategorie-Zuordnung geändert (Lebensmittel → Lebensmittel & Drogerie)"]
    end

    it "logs a YNAB category that no longer exists, and a mapping that is removed" do
      names = {"y1" => "Lebensmittel & Drogerie", "y2" => "Essen gehen"}
      store.set_ynab_category_map(household.anna, {household.food => "y1"}, names)
      store.set_ynab_category_map(household.anna, {household.restaurant => "y2", household.food => "gone"}, names)
      store.set_ynab_category_map(household.anna, {} of Int64 => String, names)

      ynab_texts.first(2).should eq [
        "YNAB: Kategorie-Zuordnung geändert (Lebensmittel → unkategorisiert (vorher (nicht mehr vorhanden)), " \
        "Restaurant → unkategorisiert (vorher Essen gehen))",
        "YNAB: Kategorie-Zuordnung geändert (Lebensmittel → (nicht mehr vorhanden) (vorher Lebensmittel & Drogerie), " \
        "Restaurant → Essen gehen)",
      ]
    end
  end

  describe "the time the target was chosen" do
    clock = Time.utc(2026, 9, 1, 10)

    before_each do
      clock = Time.utc(2026, 9, 1, 10)
      store.clock = -> { clock }
      store.set_ynab_token(household.anna, "tok")
    end

    it "is unknown until a target is chosen" do
      store.get_ynab_config(household.anna).connected_at.should be_nil

      store.set_ynab_target(household.anna, target("p", "a", "2026-09-01"))

      store.get_ynab_config(household.anna).connected_at.should eq clock
    end

    it "is kept when only the start date changes" do
      store.set_ynab_target(household.anna, target("p", "a", "2026-09-01"))
      chosen = clock
      clock += 1.hour

      store.set_ynab_target(household.anna, target("p", "a", "2026-08-01"))

      store.get_ynab_config(household.anna).connected_at.should eq chosen
    end

    it "starts anew when the account changes" do
      store.set_ynab_target(household.anna, target("p", "a", "2026-09-01"))
      clock += 1.hour

      store.set_ynab_target(household.anna, target("p", "b", "2026-09-01"))

      store.get_ynab_config(household.anna).connected_at.should eq clock
      store.list_ynab_configs.map(&.connected_at).should eq [clock]
    end

    it "is set once for legacy data without a stored time" do
      store.set_ynab_token(household.ben, "tok-b")
      store.ensure_ynab_connected_at(household.ben).should eq clock

      clock += 1.hour
      store.ensure_ynab_connected_at(household.ben).should eq clock - 1.hour
    end

    it "does not exist for a person without a connection" do
      expect_raises(Store::NotFound) { store.ensure_ynab_connected_at(household.cleo) }
    end
  end

  describe "the sync status" do
    run = Time.utc(2026, 9, 1, 10, 0, 0, nanosecond: 123456789)
    status = Store::YNABStatus.new(last_run: run, last_sync: run - 1.hour, summary: "1 neu", error: "kaputt",
      token_invalid: true, retry_at: run + 5.minutes, backoff: 10.minutes)
    without_token_state = Store::YNABStatus.new(last_run: status.last_run, last_sync: status.last_sync, summary: status.summary)

    it "does not exist without a connection" do
      expect_raises(Store::NotFound) { store.get_ynab_status(household.anna) }
      expect_raises(Store::NotFound) { store.set_ynab_status(household.anna, Store::YNABStatus.new(summary: "x")) }
    end

    it "starts empty and is stored with the precision of nanoseconds" do
      store.set_ynab_token(household.anna, "tok")
      store.get_ynab_status(household.anna).should eq Store::YNABStatus.new

      store.set_ynab_status(household.anna, status)

      store.get_ynab_status(household.anna).should eq status
      store.db.scalar("SELECT last_run || ' ' || retry_at FROM ynab_config WHERE participant_id = ?", household.anna)
        .should eq "2026-09-01T10:00:00.123456789Z 2026-09-01T10:05:00.123456789Z"
    end

    it "is not touched by choosing a target" do
      store.set_ynab_token(household.anna, "tok")
      store.set_ynab_status(household.anna, status)

      store.set_ynab_target(household.anna, target("p", "a", "2026-09-01"))

      store.get_ynab_status(household.anna).should eq status
    end

    it "loses what belonged to the old token when a new token is stored, in the same write" do
      store.set_ynab_token(household.anna, "tok")
      store.set_ynab_status(household.anna, status)

      store.set_ynab_token(household.anna, "tok-2")
      store.get_ynab_status(household.anna).should eq without_token_state

      store.set_ynab_status(household.anna, status)
      store.set_ynab_token(household.anna, "")
      store.get_ynab_status(household.anna).should eq without_token_state
    end
  end
end
