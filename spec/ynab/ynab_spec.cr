require "../web/web_helper"
require "./fake_ynab"

private alias Store = Zipfelkasse::Store
private alias Domain = Zipfelkasse::Domain
private alias YNAB = Zipfelkasse::YNAB

private PATH_TXNS = "/v1/plans/plan-1/transactions"
private POST      = "POST " + PATH_TXNS
private PATCH     = "PATCH " + PATH_TXNS
private LIST_A    = "GET /v1/plans/plan-1/accounts/acc-geteilt/transactions"

# Anna, Ben and Cleo, the fake YNAB and the service with a settable clock
# (2026-10-02 12:00 UTC).
private class Env
  getter srv : TestServer
  getter fake = YNABSpec::Fake.new
  getter svc : YNAB::Service
  property now = Time.utc(2026, 10, 2, 12, 0, 0)
  getter anna : Int64
  getter ben : Int64
  getter cleo : Int64
  getter food : Int64
  getter restaurant : Int64

  def initialize
    config = Zipfelkasse::Config.new
    config.ynab_base_url = @fake.base_url
    @srv = TestServer.new(config)
    @svc = @srv.app.ynab
    @svc.now = -> { @now }
    @anna = must_participant(st, "Anna")
    @ben = must_participant(st, "Ben")
    @cleo = must_participant(st, "Cleo")
    cats = st.list_categories(false)
    @food, @restaurant = cats[0].id, cats[1].id # Lebensmittel, Restaurant
  end

  def st : Store
    @srv.store
  end

  def close : Nil
    @fake.close
    @srv.close
  end

  # Sets up Anna's YNAB (token, plan, account, start date).
  def connect(start : String) : Nil
    st.set_ynab_token(anna, YNABSpec::TOKEN)
    st.set_ynab_target(anna, target(YNABSpec::ACCOUNT, start))
  end

  def target(account : String, start : String) : Store::YNABTarget
    Store::YNABTarget.new(plan_id: YNABSpec::PLAN, account_id: account, start: date(start))
  end

  def input(title : String, cents : Int64, d : String, payer : Int64, *who : Int64) : Store::ExpenseInput
    Store::ExpenseInput.new(title: title, date: date(d), paid_by: payer, amount_cents: cents, category_id: food,
      parts: who.map { |id| Domain::Part.new(id) }.to_a)
  end

  def create(input : Store::ExpenseInput) : Int64
    st.create_expense(input.paid_by, input)
  end

  def status : Store::YNABStatus
    svc.load_status(anna)
  end

  def sync(full : Bool) : {YNAB::SyncResult, Exception?}
    res, _, err = svc.sync_one(st.get_ynab_config(anna), full)
    {res, err}
  end

  def must_sync(full : Bool) : YNAB::SyncResult
    res, err = sync(full)
    raise err if err
    res
  end

  def expect_requests(*want : String) : Nil
    fake.take_requests.should eq want.to_a
  end

  def expect_requests : Nil
    fake.take_requests.should be_empty
  end

  def sync_rows : Hash(Int64, Store::YNABSync)
    st.list_ynab_sync(anna).to_h { |r| {r.expense_id, r} }
  end

  def get(path : String) : HTTP::Client::Response
    srv.get(path, who_cookie(anna))
  end

  def post(path : String, form = {} of String => String) : HTTP::Client::Response
    srv.post_form(path, form, who_cookie(anna))
  end

  # Sends a form while a sync (sync_all) hangs in its first request to
  # YNAB. Lets the sync go on once the handler has answered or after a short
  # wait (if the handler waits for the sync), and returns after both have
  # finished.
  def post_during_sync(path : String, form : Hash(String, String)) : HTTP::Client::Response
    hold = Channel(Nil).new
    fake.hold = hold
    fake.take_requests
    synced = Channel(Nil).new(1)
    spawn do
      svc.sync_all(false)
      synced.send(nil)
    end
    deadline = Time.instant + 3.seconds
    while fake.request_count == 0
      if Time.instant > deadline
        hold.close
        fail "sync did not start"
      end
      sleep 1.millisecond
    end
    answered = Channel(HTTP::Client::Response).new(1)
    spawn { answered.send(post(path, form)) }
    res = nil
    select
    when r = answered.receive
      res = r
    when timeout(100.milliseconds)
    end
    hold.close
    synced.receive
    res ||= answered.receive
    fake.hold = nil
    res
  end
end

private def with_env(&)
  e = Env.new
  begin
    yield e
  ensure
    e.close
  end
end

private def flash_of(res : HTTP::Client::Response) : String
  c = res.cookies[Zipfelkasse::Web::FLASH_COOKIE]? || return ""
  Base64.decode_string(c.value)
end

describe "YNAB sync" do
  it "creates, updates and deletes transactions" do
    with_env do |e|
      e.connect("2026-09-01")
      e.st.set_ynab_category_map(e.anna, {e.food => "c-food"})
      id = e.create(e.input("Einkauf Rewe", 8400, "2026-09-15", e.ben, e.anna, e.ben))

      res = e.must_sync(false)
      {res.created, res.updated + res.deleted + res.failed}.should eq({1, 0})
      e.expect_requests(POST)
      live = e.fake.live
      live.size.should eq 1
      tx = live[0]
      {tx.amount, tx.date, tx.payee_name, tx.memo, tx.category_id, tx.account_id, tx.cleared, tx.approved}.should eq(
        {-42000, "2026-09-15", "Einkauf Rewe", "Gesamt 84,00 € · bezahlt von Ben · zipfelkasse ##{id}", "c-food",
         YNABSpec::ACCOUNT, "cleared", true})
      r = e.sync_rows[id]
      r.txn_id.should eq tx.id
      r.synced_hash.should_not be_empty
      r.synced_at.should_not be_nil
      r.last_error.should be_empty

      # Idempotent: nothing changed, no request.
      e.must_sync(true).should eq YNAB::SyncResult.new
      e.expect_requests

      e.st.update_expense(e.ben, id, e.input("Einkauf Rewe groß", 10000, "2026-09-16", e.ben, e.anna, e.ben))
      res = e.must_sync(false)
      {res.updated, res.created}.should eq({1, 0})
      e.expect_requests(PATCH)
      tx = e.fake.live[0]
      {tx.amount, tx.date, tx.payee_name}.should eq({-50000, "2026-09-16", "Einkauf Rewe groß"})
      tx.memo.not_nil!.should start_with("Gesamt 100,00 €")

      e.st.delete_expense(e.ben, id)
      e.must_sync(false).deleted.should eq 1
      e.expect_requests("DELETE #{PATH_TXNS}/#{tx.id}")
      e.fake.live.should be_empty
      e.sync_rows.should be_empty
      e.must_sync(true)
      e.expect_requests

      st = e.status
      {st.last_sync, st.error, st.summary}.should eq({e.now, "", "0 neu · 0 geändert · 0 gelöscht"})
    end
  end

  it "bundles requests" do
    with_env do |e|
      e.connect("2026-09-01")
      5.times { |i| e.create(e.input("Ausgabe #{i}", 1000, "2026-09-1#{i}", e.anna, e.anna, e.ben)) }
      e.must_sync(false).created.should eq 5
      e.expect_requests(POST)
      # Renaming the payer changes all memos: a single PATCH.
      e.st.rename_participant(0_i64, e.anna, "Änna")
      e.must_sync(false).updated.should eq 5
      e.expect_requests(PATCH)
      e.fake.live.each { |tx| tx.memo.not_nil!.should contain("bezahlt von Änna") }
    end
  end

  it "keeps a category set by hand in YNAB for unmapped categories" do
    with_env do |e|
      e.connect("2026-09-01")
      id = e.create(e.input("Pizza", 3000, "2026-09-20", e.anna, e.anna, e.ben, e.cleo))
      e.must_sync(false)
      tx = e.fake.live[0]
      tx.category_id.should be_nil
      tx.amount.should eq -10000
      e.fake.txns[tx.id].category_id = "c-out"
      e.st.update_expense(e.anna, id, e.input("Pizza Napoli", 3000, "2026-09-20", e.anna, e.anna, e.ben, e.cleo))
      e.must_sync(false)
      tx = e.fake.live[0]
      {tx.category_id, tx.payee_name}.should eq({"c-out", "Pizza Napoli"})
      # With a mapping, the sync sets the category.
      e.st.set_ynab_category_map(e.anna, {e.food => "c-food"})
      e.must_sync(false).updated.should eq 1
      e.fake.live[0].category_id.should eq "c-food"
    end
  end

  it "selects expenses by start date, share, type and date" do
    with_env do |e|
      # All expenses existed before the setup (otherwise created_at counts).
      clock = Time.utc(2026, 9, 21, 10, 0, 0)
      e.st.clock = -> { clock }
      e.connect("2026-09-10")
      clock = clock.shift(days: -1)
      early = e.create(e.input("Vor dem Start", 1000, "2026-09-01", e.anna, e.anna, e.ben))
      ok = e.create(e.input("Passt", 2000, "2026-09-15", e.ben, e.anna, e.ben))
      e.create(e.input("Ohne Anna", 3000, "2026-09-15", e.anna, e.ben, e.cleo)) # Anna pays but is not involved
      e.create(e.input("Ben und Cleo", 3000, "2026-09-15", e.ben, e.ben, e.cleo))
      future = e.create(e.input("Zukunft", 4000, "2026-10-05", e.anna, e.anna, e.ben))
      reimb = e.input("Rückzahlung", 1500, "2026-09-20", e.ben, e.anna)
      reimb.reimbursement = true
      e.create(reimb)
      gone = e.create(e.input("Gelöscht", 5000, "2026-09-16", e.anna, e.anna, e.ben))
      e.st.delete_expense(e.anna, gone)

      e.must_sync(false).created.should eq 1
      live = e.fake.live
      live.size.should eq 1
      live[0].memo.not_nil!.should end_with("##{ok}")

      # Start date earlier: an earlier expense is added.
      e.st.set_ynab_target(e.anna, e.target(YNABSpec::ACCOUNT, "2026-09-01"))
      e.must_sync(false).created.should eq 1
      e.fake.live.size.should eq 2
      # Start date later: transferred transactions stay (they are only deleted
      # on deletion of the expense or share 0).
      e.st.set_ynab_target(e.anna, e.target(YNABSpec::ACCOUNT, "2026-09-16"))
      e.must_sync(false).deleted.should eq 0
      e.fake.live.size.should eq 2
      e.sync_rows.has_key?(early).should be_true
      # A future expense is added once it is due.
      e.now = Time.utc(2026, 10, 5, 8, 0, 0)
      e.must_sync(true).created.should eq 1
      live = e.fake.live
      live.size.should eq 3
      live[2].date.should eq "2026-10-05"
      # Share 0 (Anna no longer involved): DELETE.
      e.st.update_expense(e.anna, future, e.input("Zukunft", 4000, "2026-10-05", e.anna, e.ben))
      e.must_sync(false).deleted.should eq 1
      e.fake.live.size.should eq 2
    end
  end

  it "writes the original currency into the memo" do
    with_env do |e|
      e.connect("2026-09-01")
      input = e.input("Diner in NYC", Domain.to_eur_cents(9000, "USD", 1.125), "2026-09-20", e.cleo, e.anna, e.cleo)
      input.original_currency, input.original_amount_minor, input.fx_rate, input.fx_source = "USD", 9000_i64, 1.125, Domain::FX_SOURCE_ECB
      id = e.create(input)
      e.must_sync(false)
      tx = e.fake.live[0]
      {tx.memo, tx.amount}.should eq({"Gesamt 80,00 € (90,00 USD) · bezahlt von Cleo · zipfelkasse ##{id}", -40000})
    end
  end

  it "backs off after a rate limit" do
    with_env do |e|
      e.connect("2026-09-01")
      id = e.create(e.input("Kino", 2400, "2026-09-20", e.anna, e.anna, e.ben))
      e.fake.fail(429)
      _, err = e.sync(false)
      YNAB.status_of(err).should eq 429
      e.expect_requests(POST)
      st = e.status
      st.retry_at.should eq e.now + 5.minutes
      st.backoff.should eq 5.minutes
      st.error.should contain("Anfragelimit")
      r = e.sync_rows[id]
      r.synced_hash.should_not eq YNAB::PENDING_HASH
      r.txn_id.should be_empty
      # No requests during the pause.
      _, err = e.sync(false)
      err.should be_a(YNAB::BackoffError)
      e.expect_requests
      # A second 429 doubles the pause.
      e.now += 6.minutes
      e.fake.fail(429)
      e.sync(false)
      e.status.backoff.should eq 10.minutes
      e.now += 11.minutes
      e.fake.take_requests
      e.must_sync(false).created.should eq 1
      st = e.status
      {st.error, st.backoff, st.retry_at}.should eq({"", Time::Span.zero, nil})
      # sync_all schedules the next run after the pause ends.
      e.fake.fail(429)
      e.st.update_expense(e.anna, id, e.input("Kino 2", 2400, "2026-09-20", e.anna, e.anna, e.ben))
      next_run = e.svc.sync_all(false)
      next_run.should be >= 5.minutes
      next_run.should be <= 5.minutes + 1.second
    end
  end

  it "stops syncing with an invalid token until a new one is saved" do
    with_env do |e|
      e.connect("2026-09-01")
      e.st.set_ynab_token(e.anna, "falsch")
      e.create(e.input("Kino", 2400, "2026-09-20", e.anna, e.anna, e.ben))
      _, err = e.sync(false)
      YNAB.status_of(err).should eq 401
      st = e.status
      st.token_invalid?.should be_true
      st.error.should contain("Token")
      e.fake.take_requests
      _, err = e.sync(true)
      err.should be_a(YNAB::TokenInvalidError)
      e.expect_requests

      # The page shows the notice; a new token via the form resets it.
      e.get("/einstellungen/ynab").body.should contain("ungültig oder abgelaufen")
      e.post("/einstellungen/ynab/token", {"token" => YNABSpec::TOKEN}).status_code.should eq 303
      e.must_sync(false).created.should eq 1
    end
  end

  it "does not duplicate a transaction whose creation response got lost" do
    with_env do |e|
      e.connect("2026-09-01")
      id = e.create(e.input("Kino", 2400, "2026-09-20", e.anna, e.anna, e.ben))
      e.fake.lost_post = true
      _, err = e.sync(false)
      YNAB.uncertain?(err.not_nil!).should be_true
      e.sync_rows[id].synced_hash.should eq YNAB::PENDING_HASH
      e.now += 6.minutes
      e.fake.take_requests
      e.must_sync(false)
      # Searched via the memo marker instead of created again; then PATCHed.
      e.expect_requests(LIST_A, PATCH)
      live = e.fake.live
      live.size.should eq 1
      r = e.sync_rows[id]
      r.txn_id.should eq live[0].id
      r.synced_hash.should_not eq YNAB::PENDING_HASH
    end
  end

  it "recreates transactions deleted in YNAB" do
    with_env do |e|
      e.connect("2026-09-01")
      a = e.create(e.input("A", 1000, "2026-09-20", e.anna, e.anna, e.ben))
      b = e.create(e.input("B", 2000, "2026-09-21", e.anna, e.anna, e.ben))
      e.must_sync(false)
      rows = e.sync_rows
      # A deleted in YNAB (PATCH returns it as deleted), B gone entirely (404).
      e.fake.txns[rows[a].txn_id].deleted = true
      e.fake.txns.delete(rows[b].txn_id)
      e.st.update_expense(e.anna, a, e.input("A2", 1000, "2026-09-20", e.anna, e.anna, e.ben))
      e.st.update_expense(e.anna, b, e.input("B2", 2000, "2026-09-21", e.anna, e.anna, e.ben))
      e.fake.take_requests
      e.must_sync(false).again?.should be_true
      e.must_sync(false)
      e.fake.live.map(&.payee_name).should eq ["A2", "B2"]
    end
  end

  it "records a rejected transaction and retries it only in the full sync" do
    with_env do |e|
      e.connect("2026-09-01")
      good = e.create(e.input("Gut", 1000, "2026-09-20", e.anna, e.anna, e.ben))
      bad = e.create(e.input("ABLEHNEN", 2000, "2026-09-21", e.anna, e.anna, e.ben))
      res = e.must_sync(false)
      {res.created, res.failed}.should eq({1, 1})
      e.expect_requests(POST, POST, POST) # batch call rejected, then one by one
      rows = e.sync_rows
      rows[good].txn_id.should_not be_empty
      rows[bad].txn_id.should be_empty
      rows[bad].last_error.should contain("payee rejected")
      # Failed and unchanged: retried only in the full sync.
      e.must_sync(false)
      e.expect_requests
      e.must_sync(true)
      e.expect_requests(POST, POST)
      _, problems = e.st.ynab_sync_summary(e.anna)
      problems.map(&.title).should eq ["ABLEHNEN"]
    end
  end

  it "redacts the token from errors" do
    with_env do |e|
      e.connect("2026-09-01")
      e.create(e.input("Kino", 2400, "2026-09-20", e.anna, e.anna, e.ben))
      e.fake.fail(503) # the detail contains the token
      _, err = e.sync(false)
      err.should_not be_nil
      e.status.error.should_not contain(YNABSpec::TOKEN)
      e.status.error.should contain("•••")
    end
  end

  it "never blocks on trigger" do
    with_env do |e|
      start = Time.instant
      10000.times { e.svc.trigger }
      start.elapsed.should be < 2.seconds
    end
  end

  it "syncs shortly after a change" do
    with_env do |e|
      e.connect("2026-09-01")
      e.svc.debounce = 10.milliseconds
      e.svc.start_delay = 1.hour
      stopper = Zipfelkasse::Stopper.new
      stopped = Channel(Nil).new(1)
      spawn do
        e.svc.run(stopper)
        stopped.send(nil)
      end
      begin
        e.create(e.input("Kino", 2400, "2026-09-20", e.anna, e.anna, e.ben)) # hook → trigger
        deadline = Time.instant + 3.seconds
        while e.fake.live.empty?
          fail "run did not sync" if Time.instant > deadline
          sleep 5.milliseconds
        end
      ensure
        stopper.stop
        stopped.receive
      end
    end
  end

  it "aborts a hanging request on shutdown without pausing the next start" do
    with_env do |e|
      e.connect("2026-09-01")
      e.create(e.input("Kino", 2400, "2026-09-20", e.anna, e.anna, e.ben))
      e.svc.start_delay = 1.millisecond
      hold = Channel(Nil).new
      e.fake.hold = hold
      stopper = Zipfelkasse::Stopper.new
      stopped = Channel(Nil).new(1)
      spawn do
        e.svc.run(stopper)
        stopped.send(nil)
      end
      begin
        deadline = Time.instant + 3.seconds
        until e.fake.request_count > 0
          fail "run did not sync" if Time.instant > deadline
          sleep 1.millisecond
        end
        stopper.stop
        select
        when stopped.receive
        when timeout(2.seconds)
          fail "run waits for YNAB"
        end
      ensure
        hold.close
      end
      {e.status.error, e.status.retry_at}.should eq({"", nil})
      e.sync_rows.values.map(&.synced_hash).should eq [YNAB::PENDING_HASH] # the POST may have arrived
    end
  end

  it "builds postings" do
    e = Store::Expense.new(7_i64, Store::ExpenseInput.new(title: "x" * 250, date: date("2026-09-01"), amount_cents: 1000,
      original_currency: "EUR"), paid_by_name: "Anna",
      shares: [Domain::Share.new(1_i64, amount_cents: 500_i64), Domain::Share.new(2_i64, amount_cents: 500_i64)])
    p = YNAB.posting_for(e, 1_i64).not_nil!
    {p.amount_cents, p.payee.size, p.memo}.should eq({500, YNAB::MAX_PAYEE_LEN, "Gesamt 10,00 € · bezahlt von Anna · zipfelkasse #7"})
    YNAB.posting_for(e, 3_i64).should be_nil
    e.input.reimbursement = true
    YNAB.posting_for(e, 1_i64).should be_nil
    YNAB.marker_id("bla · zipfelkasse #123").should eq 123
    YNAB.marker_id("zipfelkasse #12 und mehr").should be_nil
    YNAB.marker_id("zipfelkasse #12\n").should eq 12
    YNAB.truncate("abc", 1).should eq "a"
    YNAB.truncate("abcd", 3).should eq "ab…"
  end

  it "computes the fingerprint and today" do
    p = YNAB::Posting.new(7_i64, date("2026-09-01"), 500_i64, "Kino", "memo", 0_i64)
    # fixed value: stored fingerprints must never change
    YNAB::Want.new(p, "c-food").fingerprint.should eq "d4a1ad6e19cee680676eefc66df39514"
    berlin = Time::Location.load("Europe/Berlin")
    YNAB.today(Time.utc(2026, 10, 2, 23, 30, 0), berlin).should eq date("2026-10-02")
    YNAB.today(Time.utc(2026, 10, 2, 12, 0, 0), berlin).should eq date("2026-10-02")
  end
end

describe "YNAB settings page" do
  it "connects, chooses plan, account and categories, and syncs" do
    with_env do |e|
      res = e.get("/einstellungen/ynab")
      res.status_code.should eq 200
      res.body.should contain("Verbinden")
      res.body.should contain("„Geteilt“")
      e.expect_requests # no request without a token

      # A wrong token is rejected.
      res = e.post("/einstellungen/ynab/token", {"token" => "falsch"})
      res.status_code.should eq 422
      res.body.should contain("kennt diesen Token nicht")
      expect_raises(Store::NotFound) { e.st.get_ynab_config(e.anna) }
      e.fake.take_requests

      e.post("/einstellungen/ynab/token", {"token" => YNABSpec::TOKEN}).status_code.should eq 303
      body = e.get("/einstellungen/ynab").body
      body.should_not contain(YNABSpec::TOKEN)
      ["gesetzt", %(value="plan-1|acc-geteilt"), ">Geteilt<", ">Girokonto<", %(label="Haushalt")].each { |s| body.should contain(s) }
      ["Depot", "Altes Konto"].each { |s| body.should_not contain(s) }
      e.expect_requests("GET /v1/plans") # token check; the page uses the cache

      # An unknown account is rejected.
      e.post("/einstellungen/ynab/konto", {"ziel" => "plan-1|acc-depot", "start" => "2026-09-01"}).status_code.should eq 422
      e.post("/einstellungen/ynab/konto", {"ziel" => "plan-1|acc-geteilt", "start" => "01.09.2026"}).status_code.should eq 303
      cfg = e.st.get_ynab_config(e.anna)
      {cfg.plan_id, cfg.account_id, cfg.start_date, cfg.ready?}.should eq({YNABSpec::PLAN, YNABSpec::ACCOUNT, date("2026-09-01"), true})

      body = e.get("/einstellungen/ynab").body
      [%(label="Alltag"), ">Lebensmittel &amp; Drogerie<", "Jetzt synchronisieren", %(name="kat-#{e.food}")].each { |s| body.should contain(s) }
      ["Ready to Assign", "Visa", "Versteckt", YNABSpec::TOKEN].each { |s| body.should_not contain(s) }

      e.post("/einstellungen/ynab/kategorien", {"kat-#{e.food}" => "c-gibtsnicht"}).status_code.should eq 422
      e.post("/einstellungen/ynab/kategorien", {"kat-#{e.food}" => "c-food", "kat-#{e.restaurant}" => ""}).status_code.should eq 303
      e.st.ynab_category_map(e.anna).should eq({e.food => "c-food"})
      e.get("/einstellungen/ynab").body.should contain(%(value="c-food" selected))
      e.expect_requests("GET /v1/plans/plan-1/categories") # afterwards from the cache

      e.create(e.input("Kino", 2400, "2026-09-20", e.anna, e.anna, e.ben))
      res = e.post("/einstellungen/ynab/sync")
      e.svc.wait_background
      res.status_code.should eq 303
      e.fake.live.size.should eq 1
      e.fake.live[0].category_id.should eq "c-food"
      e.get("/einstellungen/ynab").body.should contain("Synchronisierte Buchungen: <strong>1</strong>")

      # Sync errors are shown (without the token).
      e.fake.fail(503)
      e.create(e.input("Bar", 1000, "2026-09-21", e.anna, e.anna, e.ben))
      e.post("/einstellungen/ynab/sync").status_code.should eq 303
      e.svc.wait_background
      body = e.get("/einstellungen/ynab").body
      body.should contain("Fehler 503")
      body.should_not contain(YNABSpec::TOKEN)

      e.post("/einstellungen/ynab/trennen").status_code.should eq 303
      cfg = e.st.get_ynab_config(e.anna)
      cfg.token.should be_empty
      cfg.ready?.should be_false
      e.svc.sync_all(true).should eq YNAB::FULL_INTERVAL
    end
  end

  it "looks for transactions in the new account after an account change" do
    with_env do |e|
      e.connect("2026-09-01")
      e.create(e.input("Kino", 2400, "2026-09-20", e.anna, e.anna, e.ben))
      e.must_sync(false)
      e.sync_rows.size.should eq 1
      e.st.set_ynab_target(e.anna, e.target("acc-giro", "2026-09-01"))
      e.sync_rows.each_value { |r| r.txn_id.should be_empty }
      e.fake.take_requests
      e.must_sync(false).created.should eq 1
      e.expect_requests("GET /v1/plans/plan-1/accounts/acc-giro/transactions", POST)
    end
  end

  it "does not duplicate transactions when switching the account and back" do
    with_env do |e|
      e.connect("2026-09-01")
      a = e.create(e.input("A", 1000, "2026-09-20", e.anna, e.anna, e.ben))
      b = e.create(e.input("B", 2000, "2026-09-21", e.anna, e.anna, e.ben))
      gone = e.create(e.input("Weg", 3000, "2026-09-22", e.anna, e.anna, e.ben))
      e.must_sync(false)
      in_a = e.sync_rows

      e.st.set_ynab_target(e.anna, e.target("acc-giro", "2026-09-01"))
      e.must_sync(false).created.should eq 3
      # While syncing to B: one expense changes, one is deleted.
      e.st.update_expense(e.anna, a, e.input("A2", 1000, "2026-09-20", e.anna, e.anna, e.ben))
      e.st.delete_expense(e.anna, gone)
      e.must_sync(false)

      e.st.set_ynab_target(e.anna, e.target(YNABSpec::ACCOUNT, "2026-09-01"))
      e.fake.take_requests
      res = e.must_sync(false)
      {res.created, res.updated, res.deleted}.should eq({0, 2, 0})
      # No DELETE with transaction IDs of account B (they do not belong to A).
      e.expect_requests(LIST_A, PATCH)
      rows = e.sync_rows
      rows[a].txn_id.should eq in_a[a].txn_id
      rows[b].txn_id.should eq in_a[b].txn_id
      rows.has_key?(gone).should be_false
      # "Weg" was created in A before the switch and stays there (the app no
      # longer knows its transaction); A and B are not duplicated.
      e.fake.live.select(&.account_id.==(YNABSpec::ACCOUNT)).map(&.payee_name).should eq ["A2", "B", "Weg"]
      e.must_sync(false).should eq YNAB::SyncResult.new
    end
  end

  it "syncs a backdated expense entered after connecting" do
    with_env do |e|
      clock = Time.utc(2026, 9, 20, 10, 0, 0)
      e.st.clock = -> { clock }
      e.create(e.input("Vor dem Verbinden", 1000, "2026-09-01", e.anna, e.anna, e.ben))
      clock += 1.hour
      e.connect("2026-09-10")
      clock += 1.hour
      late = e.create(e.input("Nachgetragen", 2000, "2026-09-05", e.ben, e.anna, e.ben))

      e.must_sync(false).created.should eq 1
      live = e.fake.live
      live.size.should eq 1
      live[0].date.should eq "2026-09-05"
      live[0].memo.not_nil!.should end_with("##{late}")
      # An account change means a new setup: only the start date counts again.
      clock += 1.hour
      e.st.set_ynab_target(e.anna, e.target("acc-giro", "2026-09-10"))
      e.must_sync(false).created.should eq 0
    end
  end

  it "searches a lost backdated creation from its own date" do
    [false, true].each do |deleted|
      with_env do |e|
        clock = Time.utc(2026, 9, 20, 10, 0, 0)
        e.st.clock = -> { clock }
        e.connect("2026-09-10")
        clock += 1.hour
        id = e.create(e.input("Nachgetragen", 2000, "2026-09-05", e.ben, e.anna, e.ben))
        e.fake.lost_post = true
        _, err = e.sync(false)
        YNAB.uncertain?(err.not_nil!).should be_true
        e.now += 6.minutes
        e.fake.take_requests
        if deleted
          created = e.fake.live[0].id
          e.st.delete_expense(e.ben, id)
          e.must_sync(false)
          e.expect_requests(LIST_A, "DELETE #{PATH_TXNS}/#{created}")
          e.fake.live.should be_empty
        else
          e.must_sync(false)
          e.expect_requests(LIST_A, PATCH)
          live = e.fake.live
          live.size.should eq 1
          live[0].date.should eq "2026-09-05"
          e.sync_rows[id].txn_id.should eq live[0].id
        end
      end
    end
  end

  it "keeps an expense moved before the start date" do
    with_env do |e|
      clock = Time.utc(2026, 9, 20, 10, 0, 0)
      e.st.clock = -> { clock }
      id = e.create(e.input("Kino", 2400, "2026-09-15", e.anna, e.anna, e.ben))
      clock += 1.hour
      e.connect("2026-09-10")
      e.must_sync(false).created.should eq 1
      e.fake.take_requests
      e.st.update_expense(e.anna, id, e.input("Kino", 2400, "2026-09-01", e.anna, e.anna, e.ben))
      res = e.must_sync(true)
      {res.updated, res.deleted}.should eq({1, 0})
      e.expect_requests(PATCH)
      e.fake.live.map(&.date).should eq ["2026-09-01"]
      # It is only deleted when the expense is deleted.
      e.st.delete_expense(e.anna, id)
      e.must_sync(false).deleted.should eq 1
      e.fake.live.should be_empty
    end
  end

  it "deletes right away after a failed PATCH" do
    with_env do |e|
      e.connect("2026-09-01")
      id = e.create(e.input("Kino", 2400, "2026-09-20", e.anna, e.anna, e.ben))
      e.must_sync(false)
      e.st.update_expense(e.anna, id, e.input("Kino 2", 2400, "2026-09-20", e.anna, e.anna, e.ben))
      e.fake.fail(400, 400) # batch PATCH and single attempt rejected
      e.must_sync(false).failed.should eq 1
      r = e.sync_rows[id]
      r.txn_id.should_not be_empty
      r.last_error.should_not be_empty
      e.fake.take_requests
      e.st.delete_expense(e.anna, id)
      e.must_sync(false).deleted.should eq 1
      e.fake.live.should be_empty
    end
  end

  it "resets plan and account for a token of another YNAB user" do
    with_env do |e|
      e.connect("2026-09-01")
      # The same YNAB user: the target stays.
      e.post("/einstellungen/ynab/token", {"token" => YNABSpec::TOKEN}).status_code.should eq 303
      cfg = e.st.get_ynab_config(e.anna)
      {cfg.plan_id, cfg.account_id}.should eq({YNABSpec::PLAN, YNABSpec::ACCOUNT})
      res = e.post("/einstellungen/ynab/token", {"token" => YNABSpec::OTHER_TOKEN})
      res.status_code.should eq 303
      flash_of(res).should contain("neu wählen")
      cfg = e.st.get_ynab_config(e.anna)
      {cfg.token, cfg.plan_id, cfg.account_id, cfg.ready?}.should eq({YNABSpec::OTHER_TOKEN, "", "", false})
    end
  end

  it "stops the run when plan or account are not accessible" do
    with_env do |e|
      e.connect("2026-09-01")
      a = e.create(e.input("A", 1000, "2026-09-20", e.anna, e.anna, e.ben))
      b = e.create(e.input("B", 2000, "2026-09-21", e.anna, e.anna, e.ben))
      e.must_sync(false)
      before = e.sync_rows
      e.st.set_ynab_token(e.anna, YNABSpec::OTHER_TOKEN)
      check = -> do
        _, err = e.sync(false)
        YNAB.status_of(err).should eq 404
        e.status.error.should contain("Plan oder Konto")
        rows = e.sync_rows
        rows[a].txn_id.should eq before[a].txn_id
        rows[b].txn_id.should eq before[b].txn_id
      end
      e.st.delete_expense(e.anna, b)
      check.call
      e.st.update_expense(e.anna, a, e.input("A2", 1000, "2026-09-20", e.anna, e.anna, e.ben))
      check.call

      e.st.set_ynab_token(e.anna, YNABSpec::TOKEN)
      res = e.must_sync(false)
      {res.updated, res.deleted, res.created}.should eq({1, 1, 0})
      e.fake.live.map(&.payee_name).should eq ["A2"]
    end
  end

  it "retries a failed DELETE only in the full sync" do
    with_env do |e|
      e.connect("2026-09-01")
      id = e.create(e.input("Kino", 2400, "2026-09-20", e.anna, e.anna, e.ben))
      e.must_sync(false)
      del = "DELETE #{PATH_TXNS}/#{e.fake.live[0].id}"
      e.st.delete_expense(e.anna, id)
      e.fake.take_requests
      e.fake.fail(400)
      e.must_sync(false).failed.should eq 1
      e.expect_requests(del)
      r = e.sync_rows[id]
      r.txn_id.should_not be_empty
      r.last_error.should_not be_empty
      # The next change does not repeat it.
      e.create(e.input("Pizza", 3000, "2026-09-21", e.anna, e.anna, e.ben))
      res = e.must_sync(false)
      {res.created, res.failed + res.deleted}.should eq({1, 0})
      e.expect_requests(POST)
      e.must_sync(true).deleted.should eq 1
      e.expect_requests(del)
    end
  end

  it "logs a manual sync without the token and an invalid token only once" do
    with_env do |e|
      e.connect("2026-09-01")
      e.create(e.input("Kino", 2400, "2026-09-20", e.anna, e.anna, e.ben))
      sync_now = -> do
        e.srv.log_io.clear
        e.post("/einstellungen/ynab/sync").status_code.should eq 303
        e.svc.wait_background
        e.srv.log_io.to_s
      end
      e.fake.fail(503) # the detail contains the token
      log = sync_now.call
      log.should contain("sync (now) failed")
      log.should_not contain(YNABSpec::TOKEN)
      log.should contain("•••")
      e.now += 6.minutes
      e.st.set_ynab_token(e.anna, "abgelaufen")
      sync_now.call # 401: the token is marked invalid
      sync_now.call.should_not contain("failed")
    end
  end

  it "answers a manual sync without waiting for YNAB" do
    with_env do |e|
      e.connect("2026-09-01")
      e.create(e.input("Kino", 2400, "2026-09-20", e.anna, e.anna, e.ben))
      hold = Channel(Nil).new
      e.fake.hold = hold
      done = Channel(HTTP::Client::Response).new(1)
      spawn { done.send(e.post("/einstellungen/ynab/sync")) }
      select
      when res = done.receive
        res.status_code.should eq 303
        flash_of(res).should contain("Synchronisierung gestartet")
      when timeout(2.seconds)
        hold.close
        fail "POST /einstellungen/ynab/sync blocks"
      end
      hold.close
      e.svc.wait_background
      e.fake.live.size.should eq 1
    end
  end

  it "waits for a running sync before changing the account" do
    with_env do |e|
      e.connect("2026-09-01")
      id = e.create(e.input("Kino", 2400, "2026-09-20", e.anna, e.anna, e.ben))
      e.svc.plans(YNABSpec::TOKEN, true) # the handler uses the cache
      res = e.post_during_sync("/einstellungen/ynab/konto", {"ziel" => "plan-1|acc-giro", "start" => "2026-09-01"})
      res.status_code.should eq 303
      e.sync_rows[id].txn_id.should be_empty
      e.must_sync(false)
      tx = e.fake.live.find(&.id.==(e.sync_rows[id].txn_id))
      tx.try(&.account_id).should eq "acc-giro"
    end
  end

  it "keeps a new token saved during a sync valid" do
    with_env do |e|
      e.connect("2026-09-01")
      e.st.set_ynab_token(e.anna, "abgelaufen")
      e.create(e.input("Kino", 2400, "2026-09-20", e.anna, e.anna, e.ben))
      e.post_during_sync("/einstellungen/ynab/token", {"token" => YNABSpec::TOKEN}).status_code.should eq 303
      st = e.status
      st.token_invalid?.should be_false
      st.error.should be_empty
      e.must_sync(false).created.should eq 1
    end
  end

  it "logs settings changes in the activity without the token" do
    with_env do |e|
      steps = [
        {"/einstellungen/ynab/token", {"token" => YNABSpec::TOKEN}, "YNAB verbunden (Token gesetzt)"},
        {"/einstellungen/ynab/token", {"token" => YNABSpec::TOKEN}, "YNAB-Token ersetzt"},
        {"/einstellungen/ynab/konto", {"ziel" => "plan-1|acc-geteilt", "start" => "2026-09-01"},
         "YNAB: Konto „Geteilt“ im Plan „Haushalt“ gewählt, Startdatum 01.09.2026"},
        {"/einstellungen/ynab/konto", {"ziel" => "plan-1|acc-geteilt", "start" => "2026-09-15"},
         "YNAB: Startdatum 01.09.2026 → 15.09.2026"},
        {"/einstellungen/ynab/kategorien", {"kat-#{e.food}" => "c-food"},
         "YNAB: Kategorie-Zuordnung geändert (Lebensmittel → Lebensmittel & Drogerie)"},
        {"/einstellungen/ynab/trennen", {} of String => String, "YNAB-Verbindung getrennt"},
      ]
      steps.each do |path, form, want|
        e.post(path, form).status_code.should eq 303
        acts = e.st.list_activity(Store::ActivityFilter.new(limit: 1))
        acts.size.should eq 1
        {acts[0].action, acts[0].actor_id}.should eq({Store::ACTION_SETTINGS_UPDATED, e.anna})
        acts[0].details.text.should_not contain(YNABSpec::TOKEN)
        acts[0].details.text.should eq want
      end
    end
  end
end
