require "../web/web_helper"

private alias Store = Zipfelkasse::Store
private alias Domain = Zipfelkasse::Domain
private alias Recurring = Zipfelkasse::Recurring

# Fixed rates; err if set (ECB not reachable), otherwise a ValidationError
# if there is no entry (no rate exists).
private class FakeFX
  include Zipfelkasse::Web::FXRater

  getter rates = {} of String => Float64
  property err : Exception? = nil
  getter calls = [] of Time
  property on_rate : Proc(Nil)? = nil # e.g. to change a rule meanwhile

  def rate(currency : String, date : Time) : Domain::FXRate
    @calls << date
    @on_rate.try &.call
    if e = @err
      raise e
    end
    r = @rates[currency]? || raise Domain::ValidationError.new("Für #{currency} gibt es keinen EZB-Kurs.")
    Domain::FXRate.new(currency, date, r, Domain::FX_SOURCE_ECB)
  end
end

private class Env
  getter srv : TestServer
  getter svc : Recurring::Service
  getter fx = FakeFX.new
  getter anna : Int64
  getter ben : Int64

  def initialize
    config = Zipfelkasse::Config.new
    config.now = Time.local(2026, 10, 2, 12, 0, 0, location: Time::Location.load("Europe/Berlin"))
    @srv = TestServer.new(config)
    @srv.d.fx = @fx
    @svc = Recurring::Service.new(@srv.d)
    @anna = st.create_participant(0_i64, "Anna")
    @ben = st.create_participant(0_i64, "Ben")
  end

  def st : Store
    @srv.store
  end

  def expense(title : String, d : String, amount : Int64) : Store::ExpenseInput
    Store::ExpenseInput.new(title: title, date: date(d), paid_by: anna, split_mode: Domain::SPLIT_EQUAL,
      amount_cents: amount, parts: [Domain::Part.new(anna), Domain::Part.new(ben)])
  end

  # Creates an expense and makes it recurring.
  def rule(input : Store::ExpenseInput, f : Domain::Frequency) : {Int64, Int64}
    eid = st.create_expense(anna, input)
    {st.create_recurring_from_expense(anna, eid, f), eid}
  end

  def materialize(today : String, want : Int32) : Nil
    svc.materialize(date(today)).should eq want
  end

  # Ascending by date.
  def instances(rid : Int64) : Array(Store::Expense)
    st.list_expenses.reverse.select { |e| e.recurring_id == rid }
  end

  def dates(rid : Int64) : String
    instances(rid).join(" ") { |e| Store.format_date(e.date) }
  end

  # Dates of all non-deleted expenses with this title, ascending.
  def titled(title : String) : String
    st.list_expenses.reverse.select { |e| e.title == title }.join(" ") { |e| Store.format_date(e.date) }
  end

  def next(rid : Int64) : String
    Store.format_date(st.get_recurring(rid).next_date)
  end

  def get(path : String) : HTTP::Client::Response
    srv.get(path, who_cookie(ben))
  end

  def post(path : String, form = {} of String => String) : HTTP::Client::Response
    srv.post_form(path, form, who_cookie(ben))
  end

  def last_activity : Store::Activity
    acts = st.list_activity(Store::ActivityFilter.new(limit: 1))
    acts.size.should eq 1
    acts[0]
  end
end

private def with_env(&)
  e = Env.new
  begin
    yield e
  ensure
    e.srv.close
  end
end

private def flash(res : HTTP::Client::Response) : String
  c = res.cookies[Zipfelkasse::Web::FLASH_COOKIE]? || return ""
  String.new(Base64.decode(c.value))
end

describe Zipfelkasse::Recurring do
  it "clamps monthly occurrences to the month end" do
    with_env do |e|
      rid, _ = e.rule(e.expense("Miete", "2026-01-31", 100000), Domain::FREQ_MONTHLY)
      e.materialize("2026-02-27", 0)
      e.materialize("2026-05-15", 3) # three missed occurrences at once
      e.dates(rid).should eq "2026-01-31 2026-02-28 2026-03-31 2026-04-30"
      e.next(rid).should eq "2026-05-31"
      e.materialize("2026-05-15", 0)
      e.materialize("2026-05-31", 1)
      e.instances(rid).each do |x|
        {x.title, x.amount_cents, x.shares.size, x.paid_by}.should eq({"Miete", 100000, 2, e.anna})
      end
      act = e.last_activity
      {act.action, act.actor_id}.should eq({Store::ACTION_EXPENSE_CREATED, 0}) # created by the system
    end
  end

  it "handles leap years" do
    with_env do |e|
      yearly, _ = e.rule(e.expense("Versicherung", "2024-02-29", 12000), Domain::FREQ_YEARLY)
      e.materialize("2028-03-01", 4)
      e.dates(yearly).should eq "2024-02-29 2025-02-28 2026-02-28 2027-02-28 2028-02-29"
    end
  end

  it "catches up weekly occurrences" do
    with_env do |e|
      rid, _ = e.rule(e.expense("Putzen", "2026-09-01", 4000), Domain::FREQ_WEEKLY)
      e.materialize("2026-10-02", 4)
      e.dates(rid).should eq "2026-09-01 2026-09-08 2026-09-15 2026-09-22 2026-09-29"
      e.next(rid).should eq "2026-10-06"
    end
  end

  it "creates no duplicates after a crash or restart" do
    with_env do |e|
      rid, _ = e.rule(e.expense("Strom", "2026-01-15", 5000), Domain::FREQ_MONTHLY)
      # A crash: the instance for Feb 15 exists, but next_date was not advanced.
      input = e.expense("Strom", "2026-02-15", 5000)
      input.recurring_id = rid
      e.st.create_expense(0_i64, input)
      e.materialize("2026-03-20", 1) # only Mar 15 is new
      e.dates(rid).should eq "2026-01-15 2026-02-15 2026-03-15"
      # Restart: a new service on the same database.
      Recurring::Service.new(e.srv.d).materialize(date("2026-03-20")).should eq 0
      # A reset next_date creates no duplicates.
      e.st.set_recurring_next_date(rid, date("2026-04-15"), date("2026-01-15"))
      e.materialize("2026-03-20", 0)
      e.next(rid).should eq "2026-04-15"
    end
  end

  it "does not catch up paused occurrences" do
    with_env do |e|
      rid, _ = e.rule(e.expense("Kino", "2026-01-10", 2000), Domain::FREQ_MONTHLY)
      e.st.set_recurring_active(0_i64, rid, false, date("2026-01-20"))
      e.materialize("2026-05-01", 0)
      # Resumed on May 1: April and earlier are not caught up.
      e.st.set_recurring_active(0_i64, rid, true, date("2026-05-01"))
      e.materialize("2026-05-01", 0)
      e.materialize("2026-05-10", 1)
      e.dates(rid).should eq "2026-01-10 2026-05-10"
    end
  end

  it "uses the rate of the occurrence date for a foreign currency" do
    with_env do |e|
      input = e.expense("Cloud", "2026-01-05", 9091)
      input.original_currency, input.original_amount_minor, input.fx_rate, input.fx_source = "USD", 10000_i64, 1.1, Domain::FX_SOURCE_ECB
      rid, _ = e.rule(input, Domain::FREQ_MONTHLY)

      e.fx.rates["USD"] = 1.25
      e.materialize("2026-02-05", 1)
      got = e.instances(rid)[1]
      {got.amount_cents, got.fx_rate, got.original_amount_minor, got.original_currency, got.fx_source}
        .should eq({8000, 1.25, 10000, "USD", Domain::FX_SOURCE_ECB})
      e.fx.calls.should eq [date("2026-02-05")]

      # ECB not reachable: nothing is created and next_date stays, so the
      # next run catches up with the day's rate.
      e.fx.err = Exception.new("ECB not reachable")
      ex = expect_raises(Recurring::Error) { e.svc.materialize(date("2026-03-05")) }
      ex.created.should eq 0
      e.next(rid).should eq "2026-03-05"
      e.dates(rid).should eq "2026-01-05 2026-02-05"
      e.fx.err = nil
      e.materialize("2026-03-05", 1)
      got = e.instances(rid)[2]
      {got.date, got.amount_cents, got.fx_rate}.should eq({date("2026-03-05"), 8000, 1.25})

      # No rate exists for the date (a currency the ECB does not publish):
      # waiting would block the rule forever, so the template's rate is used.
      e.fx.rates.delete("USD")
      e.materialize("2026-04-05", 1)
      got = e.instances(rid)[3]
      {got.amount_cents, got.fx_rate}.should eq({9091, 1.1})
      e.next(rid).should eq "2026-05-05"
    end
  end

  it "does not carry over a manual template rate" do
    with_env do |e|
      input = e.expense("Cloud", "2026-01-05", 0)
      input.original_currency, input.original_amount_minor, input.fx_rate, input.fx_source = "USD", 10000_i64, 1.3, Domain::FX_SOURCE_MANUAL
      rid, _ = e.rule(input, Domain::FREQ_MONTHLY)
      got = e.instances(rid)[0]
      {got.amount_cents, got.fx_rate}.should eq({7692, 1.3})
      e.fx.rates["USD"] = 1.25
      e.materialize("2026-02-05", 1)
      got = e.instances(rid)[1]
      {got.amount_cents, got.fx_rate, got.fx_source}.should eq({8000, 1.25, Domain::FX_SOURCE_ECB})
    end
  end

  it "keeps fixed amounts in the foreign currency and converts the shares" do
    with_env do |e|
      input = e.expense("Hotel", "2026-01-05", 0)
      input.original_currency, input.original_amount_minor, input.fx_rate, input.fx_source = "USD", 10000_i64, 1.1, Domain::FX_SOURCE_ECB
      input.split_mode = Domain::SPLIT_AMOUNT
      input.parts = [Domain::Part.new(e.anna, 6000), Domain::Part.new(e.ben, 4000)]
      rid, _ = e.rule(input, Domain::FREQ_MONTHLY)
      e.fx.rates["USD"] = 1.25
      e.materialize("2026-02-05", 1)
      got = e.instances(rid)[1]
      {got.amount_cents, got.share_of(e.anna), got.share_of(e.ben)}.should eq({8000, 4800, 3200})
      got.parts.map(&.weight).should eq [6000, 4000]
    end
  end

  it "serves the pages and actions" do
    with_env do |e|
      res = e.get("/einstellungen/wiederkehrend")
      res.status_code.should eq 200
      res.body.should contain "Noch keine wiederkehrenden Ausgaben"
      res = e.get("/einstellungen/wiederkehrend/neu")
      res.status_code.should eq 200
      res.body.should contain "Öffne zuerst die Ausgabe"
      {"999", "abc"}.each do |q|
        e.get("/einstellungen/wiederkehrend/neu?ausgabe=#{q}").status_code.should eq 404
      end

      eid = e.st.create_expense(e.anna, e.expense("Miete", "2026-08-31", 100000))
      sid = eid.to_s
      res = e.get("/einstellungen/wiederkehrend/neu?ausgabe=#{sid}")
      res.status_code.should eq 200
      res.body.should contain "Miete"
      res.body.should contain "nächster Termin 30.09.2026"
      res.body.should contain "1 verpasster Termin wird sofort eingetragen"
      res.body.should contain "4 verpasste Termine"

      res = e.post("/einstellungen/wiederkehrend/neu", {"ausgabe" => sid, "haeufigkeit" => "taeglich"})
      res.status_code.should eq 422
      res.body.should contain "Häufigkeit"
      res = e.post("/einstellungen/wiederkehrend/neu", {"ausgabe" => sid, "haeufigkeit" => "monthly"})
      res.status_code.should eq 303
      res.headers["Location"].should eq "/einstellungen/wiederkehrend"
      rules = e.st.list_recurring
      rules.size.should eq 1
      rules[0].created_by.should eq e.ben
      rid = rules[0].id
      # Created right away: Sep 30 (today is 2026-10-02).
      e.dates(rid).should eq "2026-08-31 2026-09-30"
      e.get("/einstellungen/wiederkehrend/neu?ausgabe=#{sid}").body.should contain "gehört schon zu einer wiederkehrenden Ausgabe"
      e.post("/einstellungen/wiederkehrend/neu", {"ausgabe" => sid, "haeufigkeit" => "monthly"}).status_code.should eq 422

      body = e.get("/einstellungen/wiederkehrend").body
      {"Miete", "Monatlich seit 31.08.2026", "31.10.2026", "Pausieren"}.each { |s| body.should contain s }

      base = "/einstellungen/wiederkehrend/#{rid}"
      {
        {"pausieren", "Wiederholung „Miete“ (monatlich) pausiert"},
        {"fortsetzen", "Wiederholung „Miete“ (monatlich) fortgesetzt"},
        {"vorlage", "Wiederholung „Miete“ (monatlich): Vorlage aus der letzten Ausgabe übernommen"},
      }.each do |action, text|
        e.post("#{base}/#{action}").status_code.should eq 303
        act = e.last_activity
        {act.action, act.actor_id, act.details.text}.should eq({Store::ACTION_SETTINGS_UPDATED, e.ben, text})
        e.post("/einstellungen/wiederkehrend/999/#{action}").status_code.should eq 404
      end
      e.post("#{base}/loeschen").status_code.should eq 303
      e.post("#{base}/loeschen").status_code.should eq 404
      e.st.list_expenses.size.should eq 2
      act = e.last_activity
      {act.action, act.actor_id}.should eq({Store::ACTION_RECURRING_DELETED, e.ben})
    end
  end

  it "creates at most 400 occurrences per rule and run" do
    with_env do |e|
      rid, _ = e.rule(e.expense("Putzen", "2000-01-03", 100), Domain::FREQ_WEEKLY)
      e.materialize("2026-10-02", 400)
      e.next(rid).should eq Store.format_date(Domain.occurrence(Domain::FREQ_WEEKLY, date("2000-01-03"), 401))
      e.materialize("2026-10-02", 400)
      e.instances(rid).size.should eq 801
    end
  end

  it "runs at a fixed interval from the start, not an interval after each run" do
    with_env do |e|
      input = e.expense("Cloud", "2026-08-20", 9091)
      input.original_currency, input.original_amount_minor, input.fx_rate, input.fx_source = "USD", 10000_i64, 1.1, Domain::FX_SOURCE_ECB
      e.rule(input, Domain::FREQ_MONTHLY)
      # Every run takes 150 ms and fails, so the occurrence stays due.
      starts = [] of Time::Instant
      e.fx.on_rate = -> { starts << Time.instant; sleep 150.milliseconds }
      e.fx.err = Exception.new("ECB not reachable")
      stopper = Zipfelkasse::Stopper.new
      done = Channel(Nil).new
      spawn do
        e.svc.run(stopper, every: 200.milliseconds)
        done.close
      end
      deadline = Time.instant + 2.seconds
      until starts.size >= 2 || Time.instant > deadline
        sleep 5.milliseconds
      end
      stopper.stop
      done.receive?
      starts.size.should be >= 2
      (starts[1] - starts[0]).should be < 275.milliseconds # not 150 + 200
    end
  end

  # The run works on a snapshot of the rule and must not override the change.
  describe "a rule changed during its catch-up" do
    {
      {"paused", ->(e : Env, rid : Int64) { e.st.set_recurring_active(0_i64, rid, false, date("2026-05-10")) },
       "2026-01-05 2026-02-05", "2026-03-05"},
      {"deleted", ->(e : Env, rid : Int64) { e.st.delete_recurring(e.anna, rid) }, "", ""},
      {"paused and resumed", ->(e : Env, rid : Int64) {
        e.st.set_recurring_active(0_i64, rid, false, date("2026-05-10"))
        e.st.set_recurring_active(0_i64, rid, true, date("2026-05-10"))
      }, "2026-01-05 2026-02-05 2026-03-05", "2026-06-05"},
    }.each do |name, change, dates, next_date|
      it "stops without an error when #{name}" do
        with_env do |e|
          e.fx.rates["USD"] = 1.25
          input = e.expense("Cloud", "2026-01-05", 9091)
          input.original_currency, input.original_amount_minor, input.fx_rate, input.fx_source = "USD", 10000_i64, 1.1, Domain::FX_SOURCE_ECB
          rid, _ = e.rule(input, Domain::FREQ_MONTHLY)
          # While building the occurrence of Mar 5.
          e.fx.on_rate = -> { change.call(e, rid) if e.fx.calls.size == 2; nil }
          n = e.svc.materialize(date("2026-05-10"))
          if next_date.empty?
            n.should eq 1
            e.titled("Cloud").should eq "2026-01-05 2026-02-05"
          else
            e.dates(rid).should eq dates
            e.next(rid).should eq next_date
          end
        end
      end
    end
  end

  it "counts only the rule's own expenses in the flash" do
    with_env do |e|
      other, _ = e.rule(e.expense("Strom", "2026-08-02", 5000), Domain::FREQ_MONTHLY) # Sep 2 is due
      eid = e.st.create_expense(e.anna, e.expense("Miete", "2026-08-31", 100000))
      res = e.post("/einstellungen/wiederkehrend/neu", {"ausgabe" => eid.to_s, "haeufigkeit" => "monthly"})
      flash(res).should eq "„Miete“ wiederholt sich jetzt monatlich. 1 Ausgabe nachgetragen."
      e.dates(other).should eq "2026-08-02"

      e.st.set_recurring_active(0_i64, other, false, date("2026-08-03"))
      weekly, _ = e.rule(e.expense("Putzen", "2026-09-25", 4000), Domain::FREQ_WEEKLY) # Oct 2 is due
      # Resumed on Oct 2: the occurrence of that day is created.
      res = e.post("/einstellungen/wiederkehrend/#{other}/fortsetzen")
      flash(res).should eq "Fortgesetzt. 1 Ausgabe angelegt."
      e.dates(weekly).should eq "2026-09-25"
    end
  end

  it "describes the missed occurrences in the preview" do
    later = "eingetragen – die ersten 400 Termine sofort, der Rest in den nächsten Stunden"
    {
      {Recurring::FreqOption.new, ""},
      {Recurring::FreqOption.new(missed: 1), "1 verpasster Termin wird sofort eingetragen"},
      {Recurring::FreqOption.new(missed: 4, existing: 1),
       "3 verpasste Termine werden sofort eingetragen; 1 bereits als Ausgabe vorhandener Termin wird übersprungen"},
      {Recurring::FreqOption.new(missed: 2, existing: 2), "2 bereits als Ausgabe vorhandene Termine werden übersprungen"},
      {Recurring::FreqOption.new(missed: 400), "400 verpasste Termine werden sofort eingetragen"},
      {Recurring::FreqOption.new(missed: 610, existing: 10),
       "600 verpasste Termine werden #{later}; 10 bereits als Ausgabe vorhandene Termine werden übersprungen"},
      {Recurring::FreqOption.new(missed: 1001), "mehr als 1000 verpasste Termine werden #{later}"},
      {Recurring::FreqOption.new(missed: 1001, existing: 3),
       "mehr als 1000 verpasste Termine werden #{later}; mindestens 3 bereits als Ausgabe vorhandene Termine werden übersprungen"},
    }.each do |o, want|
      o.note.should eq want
    end

    with_env do |e|
      eid = e.st.create_expense(e.anna, e.expense("Putzen", "2000-01-03", 100))
      body = e.get("/einstellungen/wiederkehrend/neu?ausgabe=#{eid}").body
      body.should contain "mehr als 1000 verpasste Termine"
      body.should contain "der Rest in den nächsten Stunden"
    end
  end

  it "skips occurrences for which an equal expense exists" do
    with_env do |e|
      rid, _ = e.rule(e.expense("Miete", "2026-01-31", 100000), Domain::FREQ_MONTHLY)
      other_payer = e.expense("Miete", "2026-03-31", 100000)
      other_payer.paid_by = e.ben
      by_hand = [
        e.expense("Miete", "2026-02-28", 100000),  # duplicate → skipped
        e.expense("Miete", "2026-03-31", 99999),   # different amount
        e.expense("Mieten", "2026-03-31", 100000), # different title
        other_payer,
        e.expense("Miete", "2026-04-30", 100000), # deleted below
      ]
      ids = by_hand.map { |input| e.st.create_expense(e.anna, input) }
      e.st.delete_expense(e.anna, ids.last)
      e.materialize("2026-05-15", 2)
      e.dates(rid).should eq "2026-01-31 2026-03-31 2026-04-30"
      e.next(rid).should eq "2026-05-31"
    end
  end

  it "matches foreign expenses by original amount and currency" do
    with_env do |e|
      e.fx.rates["USD"] = 1.25
      input = e.expense("Cloud", "2026-01-05", 9091)
      input.original_currency, input.original_amount_minor, input.fx_rate, input.fx_source = "USD", 10000_i64, 1.1, Domain::FX_SOURCE_ECB
      rid, _ = e.rule(input, Domain::FREQ_MONTHLY)
      dup = input
      dup.date, dup.amount_cents, dup.fx_rate = date("2026-02-05"), 9000_i64, 1.111
      e.st.create_expense(e.anna, dup)
      e.materialize("2026-03-05", 1)
      e.dates(rid).should eq "2026-01-05 2026-03-05"
      e.fx.calls.size.should eq 1 # only for 2026-03-05
    end
  end

  it "does not enter the occurrences of a deleted rule again when it is recreated" do
    with_env do |e|
      rid, eid = e.rule(e.expense("Miete", "2026-01-31", 100000), Domain::FREQ_MONTHLY)
      e.materialize("2026-05-15", 3)
      e.st.delete_recurring(e.anna, rid)
      body = e.get("/einstellungen/wiederkehrend/neu?ausgabe=#{eid}").body
      body.should contain "5 verpasste Termine werden sofort eingetragen"
      body.should contain "3 bereits als Ausgabe vorhandene Termine werden übersprungen"
      res = e.post("/einstellungen/wiederkehrend/neu", {"ausgabe" => eid.to_s, "haeufigkeit" => "monthly"})
      res.status_code.should eq 303
      e.titled("Miete").should eq "2026-01-31 2026-02-28 2026-03-31 2026-04-30 2026-05-31 2026-06-30 2026-07-31 2026-08-31 2026-09-30"
    end
  end
end
