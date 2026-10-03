require "../spec_helper"
require "csv"

private def payees(download : Export::Download) : Array(String)
  CSV.parse(download.body).skip(1).map(&.[1])
end

private def service : Export::Service
  Export::Service.new(household.deps)
end

private def everyone : Export::Period
  Export::Period.new
end

describe Export::Service do
  use_household

  before_each do
    household.now = Time.utc(2026, 10, 3, 10)
    store.clock = -> { Time.utc(2026, 9, 10) }
    household.create(household.equal("Brötchen", 400, "2026-08-30", household.ben, household.anna, household.ben), household.ben)
    household.create(household.equal("Käse", 1000, "2026-09-02", household.ben, household.anna, household.ben), household.ben)
    household.create(household.equal("Nur Ben", 700, "2026-09-04", household.ben, household.ben), household.ben)
    deleted = household.create(household.equal("Gelöscht", 999, "2026-09-03", household.anna, household.anna, household.ben))
    store.delete_expense(household.anna, deleted)
  end

  describe "#ynab_csv" do
    it "contains the person's postings of past expenses without a YNAB connection" do
      household.create(household.equal("Zukunft", 800, "2026-10-04", household.ben, household.anna, household.ben), household.ben)

      payees(service.ynab_csv(store.get_participant(household.anna), everyone)).should eq ["Brötchen", "Käse"]
    end

    it "contains what the YNAB sync transfers for a connected person" do
      connected_at = Time.utc(2026, 9, 21, 12)
      store.clock = -> { connected_at }
      store.set_ynab_token(household.anna, "token")
      store.set_ynab_target(household.anna, Store::YNABTarget.new("plan", "account", start: date("2026-09-01")))
      store.clock = -> { connected_at + 1.minute }
      household.create(household.equal("Nachgetragen", 600, "2026-08-15", household.ben, household.anna, household.ben), household.ben)

      payees(service.ynab_csv(store.get_participant(household.anna), everyone)).should eq ["Nachgetragen", "Käse"]
    end

    it "keeps an expense that is already in YNAB although it is dated before the start" do
      connected_at = Time.utc(2026, 9, 21, 12)
      store.clock = -> { connected_at }
      store.set_ynab_token(household.anna, "token")
      store.set_ynab_target(household.anna, Store::YNABTarget.new("plan", "account", start: date("2026-09-01")))
      store.put_ynab_sync(Store::YNABSync.synced(1_i64, household.anna, "t1", "hash", Time.utc(2026, 9, 1)))

      payees(service.ynab_csv(store.get_participant(household.anna), everyone)).should eq ["Brötchen", "Käse"]
    end

    it "writes nothing to the database" do
      store.set_ynab_token(household.anna, "token")
      store.set_ynab_target(household.anna, Store::YNABTarget.new("plan", "account", start: date("2026-09-01")))
      store.db.exec("UPDATE ynab_config SET connected_at = NULL")

      service.ynab_csv(store.get_participant(household.anna), everyone)

      store.get_ynab_config(household.anna).connected_at.should be_nil
    end
  end

  describe "#ynab_ofx" do
    it "contains the same postings as the CSV, limited to the period" do
      period = Export::Period.new(from: date("2026-09-01"))
      ofx = service.ynab_ofx(store.get_participant(household.anna), period).body

      ofx.scan("<STMTTRN>").size.should eq 1
      ofx.should contain "<NAME>Käse\r\n"
    end
  end
end
