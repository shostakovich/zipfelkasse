require "../spec_helper"

private TRANSACTIONS = "/v1/plans/plan-1/transactions"
private POST         = "POST " + TRANSACTIONS
private PATCH        = "PATCH " + TRANSACTIONS
private LIST_SHARED  = "GET /v1/plans/plan-1/accounts/acc-geteilt/transactions"
private LIST_GIRO    = "GET /v1/plans/plan-1/accounts/acc-giro/transactions"

private module Fixture
  class_property! fake : FakeYNAB
  class_property! service : YNAB::Service
  class_property now : Time = Time.utc(2026, 10, 2, 12)
end

private def fake : FakeYNAB
  Fixture.fake
end

private def service : YNAB::Service
  Fixture.service
end

private def anna : Int64
  household.anna
end

private def advance(span : Time::Span) : Nil
  Fixture.now += span
end

private def target(account : String, start : String) : Store::YNABTarget
  Store::YNABTarget.new(plan_id: FakeYNAB::PLAN, account_id: account, start: date(start))
end

# Anna's YNAB: the token, the shared account and the start date.
private def connect(start : String = "2026-09-01", account : String = FakeYNAB::ACCOUNT) : Nil
  store.set_ynab_token(anna, FakeYNAB::TOKEN)
  store.set_ynab_target(anna, target(account, start))
end

# An expense Anna pays and shares with Ben, in the category Lebensmittel.
private def shared(title : String, cents : Int64, on : String) : Store::ExpenseInput
  household.equal(title, cents, on, anna, anna, household.ben)
end

private def create(input : Store::ExpenseInput) : Int64
  household.create(input)
end

private def edit(expense_id : Int64, & : Store::ExpenseInput -> Store::ExpenseInput) : Nil
  store.update_expense(anna, expense_id, yield store.get_expense(expense_id).to_input)
end

private def sync(full : Bool = false) : YNAB::Outcome
  service.sync_person(anna, full)
end

# The result of a sync that must succeed.
private def sync!(full : Bool = false) : YNAB::SyncResult
  outcome = sync(full)
  raise outcome.error.not_nil! if outcome.error
  outcome.result
end

private def status : Store::YNABStatus
  service.load_status(anna)
end

private def rows : Hash(Int64, Store::YNABSync)
  store.list_ynab_sync(anna).to_h { |row| {row.expense_id, row} }
end

private def requests : Array(String)
  fake.take_requests
end

# A sync that hangs in its first request to YNAB until it is released.
private record HungSync, hold : Channel(Nil), done : Channel(Nil) do
  def release : Nil
    hold.close
    done.receive?
  end
end

private def hang_a_sync : HungSync
  hold = Channel(Nil).new
  fake.hold = hold
  fake.take_requests
  done = Channel(Nil).new
  spawn do
    service.sync_all(false)
    done.close
  end
  eventually { fake.request_count > 0 }
  HungSync.new(hold, done)
end

describe YNAB::Service do
  use_household

  around_each do |example|
    Fixture.fake = FakeYNAB.new
    Fixture.now = Time.utc(2026, 10, 2, 12)
    Fixture.service = YNAB::Service.new(household.deps)
    service.base_url = fake.base_url
    service.now = -> { Fixture.now }
    begin
      example.run
    ensure
      service.stop
      fake.close
    end
  end

  describe "creating, updating and deleting transactions" do
    it "creates a transaction with the person's share as an outflow in the mapped category" do
      connect
      store.set_ynab_category_map(anna, {household.food => "c-food"})
      id = create(shared("Einkauf Rewe", 8400, "2026-09-15"))

      sync!.created.should eq 1

      requests.should eq [POST]
      transaction = fake.live.first
      {transaction.amount, transaction.date, transaction.payee_name, transaction.category_id, transaction.account_id,
       transaction.cleared, transaction.approved}
        .should eq({-42000, "2026-09-15", "Einkauf Rewe", "c-food", FakeYNAB::ACCOUNT, "cleared", true})
      transaction.memo.should eq "Gesamt 84,00 € · bezahlt von Anna · zipfelkasse ##{id}"
      row = rows[id]
      {row.txn_id, row.synced_hash.nil?, row.synced_at.nil?, row.last_error}.should eq({transaction.id, false, false, nil})
    end

    it "sends nothing when nothing changed, not even in a full sync" do
      connect
      create(shared("Einkauf", 8400, "2026-09-15"))
      sync!

      requests
      sync!(true).should eq YNAB::SyncResult.new
      requests.should be_empty
    end

    it "updates the transaction of a changed expense" do
      connect
      id = create(shared("Einkauf", 8400, "2026-09-15"))
      sync!
      edit(id) { |input| input.title, input.amount_cents, input.date = "Einkauf groß", 10000_i64, date("2026-09-16"); input }

      sync!.updated.should eq 1

      requests.should eq [POST, PATCH]
      transaction = fake.live.first
      {transaction.amount, transaction.date, transaction.payee_name}.should eq({-50000, "2026-09-16", "Einkauf groß"})
      transaction.memo.not_nil!.should start_with "Gesamt 100,00 €"
    end

    it "deletes the transaction of a deleted expense and forgets it" do
      connect
      id = create(shared("Einkauf", 8400, "2026-09-15"))
      sync!
      transaction_id = fake.live.first.id

      store.delete_expense(anna, id)
      sync!.deleted.should eq 1

      requests.last.should eq "DELETE #{TRANSACTIONS}/#{transaction_id}"
      fake.live.should be_empty
      rows.should be_empty
    end

    it "remembers the result of the last sync in the status" do
      connect
      create(shared("Einkauf", 8400, "2026-09-15"))
      sync!

      {status.last_sync, status.error, status.summary}.should eq({Fixture.now, nil, "1 neu · 0 geändert · 0 gelöscht"})
    end

    it "bundles all changes of one kind into a single request" do
      connect
      5.times { |i| create(shared("Ausgabe #{i}", 1000, "2026-09-1#{i}")) }
      sync!.created.should eq 5
      requests.should eq [POST]

      store.rename_participant(nil, anna, "Änna")
      sync!.updated.should eq 5

      requests.should eq [PATCH]
      fake.live.each { |transaction| transaction.memo.not_nil!.should contain "bezahlt von Änna" }
    end

    it "writes the original currency into the memo" do
      connect
      id = create(household.foreign("Diner in NYC", 9000, "USD", 1.125, "2026-09-20", household.cleo, anna, household.cleo))

      sync!

      transaction = fake.live.first
      transaction.memo.should eq "Gesamt 80,00 € (90,00 USD) · bezahlt von Cleo · zipfelkasse ##{id}"
      transaction.amount.should eq -40000
    end

    it "keeps a category set by hand in YNAB while the app category is not mapped" do
      connect
      id = create(shared("Pizza", 3000, "2026-09-20"))
      sync!
      fake.txns[fake.live.first.id].category_id = "c-out"
      edit(id) { |input| input.title = "Pizza Napoli"; input }

      sync!
      {fake.live.first.category_id, fake.live.first.payee_name}.should eq({"c-out", "Pizza Napoli"})

      store.set_ynab_category_map(anna, {household.food => "c-food"})
      sync!.updated.should eq 1
      fake.live.first.category_id.should eq "c-food"
    end
  end

  describe "selecting the expenses" do
    # The expenses of these examples exist before the setup, unless they say otherwise.
    before_each do
      store.clock = -> { Time.utc(2026, 9, 21, 10) }
      connect("2026-09-10")
      store.clock = -> { Time.utc(2026, 9, 20, 10) }
    end

    it "takes only the person's shares of expenses from the start date on" do
      create(shared("Vor dem Start", 1000, "2026-09-01"))
      ok = create(shared("Passt", 2000, "2026-09-15"))
      create(household.equal("Ohne Anna", 3000, "2026-09-15", anna, household.ben, household.cleo))
      create(household.equal("Ben und Cleo", 3000, "2026-09-15", household.ben, household.ben, household.cleo))
      create(shared("Zukunft", 4000, "2026-10-05"))
      create(household.reimbursement(1500, "2026-09-20", household.ben, anna))
      gone = create(shared("Gelöscht", 5000, "2026-09-16"))
      store.delete_expense(anna, gone)

      sync!.created.should eq 1

      fake.live.map(&.memo.not_nil!.split("#").last).should eq [ok.to_s]
    end

    it "adds an earlier expense when the start date moves back" do
      create(shared("Vor dem Start", 1000, "2026-09-01"))
      create(shared("Passt", 2000, "2026-09-15"))
      sync!
      store.set_ynab_target(anna, target(FakeYNAB::ACCOUNT, "2026-09-01"))

      sync!.created.should eq 1
      fake.live.size.should eq 2
    end

    it "keeps transferred transactions when the start date moves forward" do
      early = create(shared("Früh", 1000, "2026-09-12"))
      sync!
      store.set_ynab_target(anna, target(FakeYNAB::ACCOUNT, "2026-09-16"))

      sync!.deleted.should eq 0
      fake.live.size.should eq 1
      rows.has_key?(early).should be_true
    end

    it "adds a future expense once it is due" do
      create(shared("Zukunft", 4000, "2026-10-05"))
      sync!.created.should eq 0

      advance(3.days)
      sync!(true).created.should eq 1
      fake.live.map(&.date).should eq ["2026-10-05"]
    end

    it "deletes the transaction when the person no longer has a share" do
      id = create(shared("Gemeinsam", 4000, "2026-09-15"))
      sync!
      edit(id) { |input| input.parts = [Domain::Part.new(household.ben)]; input }

      sync!.deleted.should eq 1
      fake.live.should be_empty
    end

    it "syncs a backdated expense entered after connecting" do
      store.clock = -> { Time.utc(2026, 9, 22, 10) }
      late = create(shared("Nachgetragen", 2000, "2026-09-05"))

      sync!.created.should eq 1
      fake.live.map { |transaction| {transaction.date, transaction.memo.not_nil!.split("#").last} }.should eq [{"2026-09-05", late.to_s}]
    end

    it "treats a change of the account as a new setup that only looks at the start date" do
      store.clock = -> { Time.utc(2026, 9, 22, 10) }
      create(shared("Nachgetragen", 2000, "2026-09-05"))
      sync!
      store.clock = -> { Time.utc(2026, 9, 23, 10) }

      store.set_ynab_target(anna, target("acc-giro", "2026-09-10"))
      sync!.created.should eq 0
    end

    it "keeps an expense that is moved before the start date" do
      id = create(shared("Kino", 2400, "2026-09-15"))
      sync!
      requests
      edit(id) { |input| input.date = date("2026-09-01"); input }

      result = sync!(true)

      {result.updated, result.deleted}.should eq({1, 0})
      requests.should eq [PATCH]
      fake.live.map(&.date).should eq ["2026-09-01"]
    end
  end

  describe "when YNAB does not answer clearly" do
    it "does not create a transaction twice when the response of its creation got lost" do
      connect
      id = create(shared("Kino", 2400, "2026-09-20"))
      fake.lost_post = true
      sync.failure.should eq YNAB::Failure::Unclear
      rows[id].pending?.should be_true

      advance(6.minutes)
      requests
      sync!

      requests.should eq [LIST_SHARED, PATCH]
      fake.live.size.should eq 1
      {rows[id].txn_id, rows[id].pending?}.should eq({fake.live.first.id, false})
    end

    it "searches a lost creation from the date of its own expense" do
      store.clock = -> { Time.utc(2026, 9, 20, 10) }
      connect("2026-09-10")
      store.clock = -> { Time.utc(2026, 9, 21, 10) }
      id = create(shared("Nachgetragen", 2000, "2026-09-05"))
      fake.lost_post = true
      sync.failure.should eq YNAB::Failure::Unclear
      advance(6.minutes)
      requests

      sync!

      requests.should eq [LIST_SHARED, PATCH]
      fake.live.map(&.date).should eq ["2026-09-05"]
      rows[id].txn_id.should eq fake.live.first.id
    end

    it "deletes the transaction of an expense deleted while its creation was unclear" do
      connect
      id = create(shared("Kino", 2400, "2026-09-20"))
      fake.lost_post = true
      sync
      created = fake.live.first.id
      store.delete_expense(anna, id)
      advance(6.minutes)
      requests

      sync!

      requests.should eq [LIST_SHARED, "DELETE #{TRANSACTIONS}/#{created}"]
      fake.live.should be_empty
    end

    it "finds a transaction of unclear outcome after its date moved behind the start date" do
      store.clock = -> { Time.utc(2026, 9, 20, 10) }
      connect("2026-09-10")
      store.clock = -> { Time.utc(2026, 9, 21, 10) }
      id = create(shared("Nachgetragen", 2000, "2026-09-05"))
      fake.lost_post = true
      sync.failure.should eq YNAB::Failure::Unclear
      edit(id) { |input| input.date = date("2026-09-20"); input }
      advance(6.minutes)

      sync!

      fake.live.map(&.date).should eq ["2026-09-20"]
      rows[id].txn_id.should eq fake.live.first.id
    end

    it "treats an answer without data as an unclear outcome, never as an empty list" do
      connect
      id = create(shared("Kino", 2400, "2026-09-20"))
      fake.lost_post = true
      sync.failure.should eq YNAB::Failure::Unclear
      fake.bare_list = true
      advance(6.minutes)
      requests

      sync.failure.should eq YNAB::Failure::Unclear

      requests.should eq [LIST_SHARED]
      fake.live.size.should eq 1
      rows[id].pending?.should be_true

      fake.bare_list = false
      advance(6.minutes)
      sync!
      fake.live.size.should eq 1
    end

    it "recreates transactions that were deleted in YNAB" do
      connect
      a = create(shared("A", 1000, "2026-09-20"))
      b = create(shared("B", 2000, "2026-09-21"))
      sync!
      transaction_ids = rows.transform_values(&.txn_id)
      fake.txns[transaction_ids[a]].deleted = true # a PATCH returns it as deleted
      fake.txns.delete(transaction_ids[b])         # a PATCH answers 404
      edit(a) { |input| input.title = "A2"; input }
      edit(b) { |input| input.title = "B2"; input }

      sync!.again?.should be_true
      sync!

      fake.live.map(&.payee_name).should eq ["A2", "B2"]
    end

    it "aborts a hanging request on shutdown without pausing the next start" do
      connect
      create(shared("Kino", 2400, "2026-09-20"))
      service.start_delay = 1.millisecond
      hold = Channel(Nil).new
      fake.hold = hold
      stopper = Zipfelkasse::Stopper.new
      stopped = Channel(Nil).new
      spawn do
        service.run(stopper)
        stopped.close
      end
      begin
        eventually { fake.request_count > 0 }
        stopper.stop
        select
        when stopped.receive?
        when timeout(2.seconds)
          fail "run waits for YNAB"
        end
      ensure
        hold.close
      end

      {status.error, status.retry_at}.should eq({nil, nil})
      rows.values.map(&.pending?).should eq [true]
    end
  end

  describe "when YNAB refuses" do
    it "backs off after a rate limit and sends nothing during the pause" do
      connect
      id = create(shared("Kino", 2400, "2026-09-20"))
      fake.fail(429)

      sync.failure.should eq YNAB::Failure::RateLimited

      requests.should eq [POST]
      {status.retry_at, status.backoff}.should eq({Fixture.now + 5.minutes, 5.minutes})
      status.error.to_s.should contain "Anfragelimit"
      {rows[id].pending?, rows[id].txn_id}.should eq({false, nil})
      sync.skipped.should eq YNAB::Skip::BackedOff
      requests.should be_empty
    end

    it "doubles the pause on every further rate limit and resets it after a success" do
      connect
      create(shared("Kino", 2400, "2026-09-20"))
      fake.fail(429)
      sync
      advance(6.minutes)
      fake.fail(429)
      sync
      status.backoff.should eq 10.minutes

      advance(11.minutes)
      sync!.created.should eq 1

      {status.error, status.backoff, status.retry_at}.should eq({nil, Time::Span.zero, nil})
    end

    it "schedules the next run for the end of the pause" do
      connect
      id = create(shared("Kino", 2400, "2026-09-20"))
      sync!
      fake.fail(429)
      edit(id) { |input| input.title = "Kino 2"; input }

      next_run = service.sync_all(false)

      next_run.should be >= 5.minutes
      next_run.should be <= 5.minutes + 1.second
    end

    it "stops syncing with an invalid token until a new one is saved" do
      connect
      store.set_ynab_token(anna, "wrong")
      create(shared("Kino", 2400, "2026-09-20"))

      sync.failure.should eq YNAB::Failure::Unauthorized
      status.token_invalid?.should be_true
      status.error.to_s.should contain "Token"
      requests
      sync(true).skipped.should eq YNAB::Skip::TokenInvalid
      requests.should be_empty

      store.set_ynab_token(anna, FakeYNAB::TOKEN)
      sync!.created.should eq 1
    end

    it "records a rejected transaction and retries it only in the full sync" do
      connect
      good = create(shared("Gut", 1000, "2026-09-20"))
      bad = create(shared("REJECT", 2000, "2026-09-21"))

      result = sync!
      {result.created, result.failed}.should eq({1, 1})
      requests.should eq [POST, POST, POST] # the batch is rejected, then each one is tried
      rows[good].txn_id.should_not be_nil
      rows[bad].txn_id.should be_nil
      rows[bad].last_error.to_s.should contain "payee rejected"

      sync!
      requests.should be_empty
      sync!(true)
      requests.should eq [POST, POST]
      store.ynab_sync_summary(anna)[1].map(&.title).should eq ["REJECT"]
    end

    it "deletes right away what a failed PATCH could not update" do
      connect
      id = create(shared("Kino", 2400, "2026-09-20"))
      sync!
      edit(id) { |input| input.title = "Kino 2"; input }
      fake.fail(400, 400) # the batch and the single attempt

      sync!.failed.should eq 1
      {rows[id].txn_id.nil?, rows[id].last_error.nil?}.should eq({false, false})

      store.delete_expense(anna, id)
      sync!.deleted.should eq 1
      fake.live.should be_empty
    end

    it "retries a failed DELETE only in the full sync" do
      connect
      id = create(shared("Kino", 2400, "2026-09-20"))
      sync!
      deletion = "DELETE #{TRANSACTIONS}/#{fake.live.first.id}"
      store.delete_expense(anna, id)
      requests
      fake.fail(400)

      sync!.failed.should eq 1
      requests.should eq [deletion]
      {rows[id].txn_id.nil?, rows[id].last_error.nil?}.should eq({false, false})

      create(shared("Pizza", 3000, "2026-09-21"))
      result = sync!
      {result.created, result.failed + result.deleted}.should eq({1, 0})
      requests.should eq [POST]
      sync!(true).deleted.should eq 1
      requests.should eq [deletion]
    end

    it "stops the run when plan or account are not accessible" do
      connect
      a = create(shared("A", 1000, "2026-09-20"))
      b = create(shared("B", 2000, "2026-09-21"))
      sync!
      before = rows
      store.set_ynab_token(anna, FakeYNAB::OTHER_TOKEN)

      store.delete_expense(anna, b)
      sync.failure.should eq YNAB::Failure::NotFound
      status.error.to_s.should contain "Plan oder Konto"
      edit(a) { |input| input.title = "A2"; input }
      sync.failure.should eq YNAB::Failure::NotFound
      rows.transform_values(&.txn_id).should eq before.transform_values(&.txn_id)

      store.set_ynab_token(anna, FakeYNAB::TOKEN)
      result = sync!
      {result.updated, result.deleted, result.created}.should eq({1, 1, 0})
      fake.live.map(&.payee_name).should eq ["A2"]
    end

    it "redacts the token from errors" do
      connect
      create(shared("Kino", 2400, "2026-09-20"))
      fake.fail(503)

      sync.error.should_not be_nil

      status.error.to_s.should_not contain FakeYNAB::TOKEN
      status.error.to_s.should contain "•••"
    end
  end

  describe "changing the account" do
    it "looks for the transactions in the new account" do
      connect
      create(shared("Kino", 2400, "2026-09-20"))
      sync!
      store.set_ynab_target(anna, target("acc-giro", "2026-09-01"))
      rows.each_value { |row| row.txn_id.should be_nil }
      requests

      sync!.created.should eq 1

      requests.should eq [LIST_GIRO, POST]
    end

    it "does not duplicate transactions when switching the account and back" do
      connect
      a = create(shared("A", 1000, "2026-09-20"))
      b = create(shared("B", 2000, "2026-09-21"))
      gone = create(shared("Weg", 3000, "2026-09-22"))
      sync!
      in_shared = rows

      store.set_ynab_target(anna, target("acc-giro", "2026-09-01"))
      sync!.created.should eq 3
      edit(a) { |input| input.title = "A2"; input }
      store.delete_expense(anna, gone)
      sync!

      store.set_ynab_target(anna, target(FakeYNAB::ACCOUNT, "2026-09-01"))
      requests
      result = sync!

      {result.created, result.updated, result.deleted}.should eq({0, 2, 0})
      requests.should eq [LIST_SHARED, PATCH]
      rows[a].txn_id.should eq in_shared[a].txn_id
      rows[b].txn_id.should eq in_shared[b].txn_id
      rows.has_key?(gone).should be_false
      fake.live.select(&.account_id.==(FakeYNAB::ACCOUNT)).map(&.payee_name).should eq ["A2", "B", "Weg"]
      sync!.should eq YNAB::SyncResult.new
    end

    it "waits for a running sync before changing the account" do
      connect
      id = create(shared("Kino", 2400, "2026-09-20"))
      sync = hang_a_sync
      changed = Channel(Nil).new
      spawn do
        service.change_connection { store.set_ynab_target(anna, target("acc-giro", "2026-09-01")) }
        changed.close
      end

      select
      when changed.receive?
        fail "the account was changed during the sync"
      when timeout(100.milliseconds)
      end
      sync.release
      changed.receive?

      rows[id].txn_id.should be_nil
      fake.hold = nil
      sync!
      fake.live.find(&.id.==(rows[id].txn_id)).not_nil!.account_id.should eq "acc-giro"
    end

    it "keeps a new token that is saved during a sync valid" do
      connect
      store.set_ynab_token(anna, "expired")
      create(shared("Kino", 2400, "2026-09-20"))
      sync = hang_a_sync
      changed = Channel(Nil).new
      spawn do
        service.change_connection { store.set_ynab_token(anna, FakeYNAB::TOKEN) }
        changed.close
      end
      sleep 50.milliseconds
      sync.release
      changed.receive?

      {status.token_invalid?, status.error}.should eq({false, nil})
      fake.hold = nil
      sync!.created.should eq 1
    end
  end

  describe "manual and background syncs" do
    it "logs a manual sync without the token, and an invalid token only once" do
      connect
      create(shared("Kino", 2400, "2026-09-20"))
      fake.fail(503)

      service.sync_person(anna, true, manual: true)
      SPEC_LOG.to_s.should contain "sync (now) failed"
      SPEC_LOG.to_s.should_not contain FakeYNAB::TOKEN
      SPEC_LOG.to_s.should contain "•••"

      advance(6.minutes)
      store.set_ynab_token(anna, "expired")
      service.sync_person(anna, true, manual: true)
      SPEC_LOG.clear
      service.sync_person(anna, true, manual: true)
      SPEC_LOG.to_s.should_not contain "failed"
    end

    it "answers a manual sync without waiting for YNAB" do
      connect
      create(shared("Kino", 2400, "2026-09-20"))
      hold = Channel(Nil).new
      fake.hold = hold

      started = Time.instant
      service.sync_in_background(anna)
      (Time.instant - started).should be < 1.second

      hold.close
      service.wait_background
      fake.live.size.should eq 1
    end

    it "never blocks when it is triggered" do
      started = Time.instant
      10_000.times { service.trigger }
      (Time.instant - started).should be < 2.seconds
    end

    it "syncs shortly after a change" do
      connect
      service.debounce = 10.milliseconds
      service.start_delay = 1.hour
      stopper = Zipfelkasse::Stopper.new
      stopped = Channel(Nil).new
      spawn do
        service.run(stopper)
        stopped.close
      end

      begin
        create(shared("Kino", 2400, "2026-09-20"))
        eventually { !fake.live.empty? }
      ensure
        stopper.stop
        stopped.receive?
      end
    end
  end
end
