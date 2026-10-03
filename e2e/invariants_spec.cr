require "./e2e_helper"
require "csv"

private alias W = E2E::Web

# What the shared seed household holds, read straight from the database.
# Everything the app shows or exports is compared with this.
private class Ledger
  record Expense, id : Int64, title : String, date : String, paid_by : Int64, amount : Int64, currency : String,
    minor : Int64, rate : Float64, source : String, mode : String, notes : String, category_id : Int64?,
    reimbursement : Bool, deleted : Bool, created_at : String, updated_at : String, shares : Hash(Int64, Int64)

  # Currencies the app shows with other than two decimals.
  DECIMALS = {"JPY" => 0, "IDR" => 0, "KWD" => 3}

  getter expenses : Array(Expense)
  getter people : Hash(Int64, String)
  getter archived : Set(Int64)
  getter path : String

  def initialize(@path)
    shares = Hash(Int64, Hash(Int64, Int64)).new { |h, k| h[k] = {} of Int64 => Int64 }
    rows = [] of Tuple(Int64, String, String, Int64, Int64, String, Int64, Float64, String, String, String, Int64?, Int64, String?, String, String)
    people = {} of Int64 => String
    archived = Set(Int64).new
    E2E::Database.open(path) do |db|
      db.query_each("SELECT expense_id, participant_id, amount_cents FROM expense_shares") do |rs|
        id, who, cents = rs.read(Int64, Int64, Int64)
        shares[id][who] = cents
      end
      rows = db.query_all(<<-SQL, as: {Int64, String, String, Int64, Int64, String, Int64, Float64, String, String, String, Int64?, Int64, String?, String, String})
        SELECT id, title, date, paid_by, amount_cents, original_currency, original_amount_minor, fx_rate, fx_source,
               split_mode, notes, category_id, is_reimbursement, deleted_at, created_at, updated_at
        FROM expenses ORDER BY id
        SQL
      people = db.query_all("SELECT id, name FROM participants", as: {Int64, String}).to_h
      archived = db.query_all("SELECT id FROM participants WHERE archived_at IS NOT NULL", as: Int64).to_set
    end
    @expenses = rows.map do |r|
      Expense.new(r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10], r[11], r[12] == 1, !r[13].nil?, r[14], r[15], shares[r[0]])
    end
    @people = people
    @archived = archived
  end

  def live : Array(Expense)
    @expenses.reject(&.deleted)
  end

  # Oldest first, like the exports.
  def chronological : Array(Expense)
    live.sort_by { |e| {e.date, e.id} }
  end

  # Newest first, like the home page.
  def listed : Array(Expense)
    live.sort_by { |e| {e.date, e.id} }.reverse
  end

  # Positive: is owed money; negative: owes money.
  def balances : Hash(Int64, Int64)
    out = Hash(Int64, Int64).new(0_i64)
    live.each do |e|
      out[e.paid_by] += e.amount
      e.shares.each { |who, cents| out[who] -= cents }
    end
    @people.each_key { |id| out[id] }
    out
  end

  def self.euro(cents : Int64) : String
    sign = cents < 0 ? "-" : ""
    whole = (cents.abs // 100).to_s.gsub(/(\d)(?=(\d{3})+$)/, "\\1.")
    "#{sign}#{whole},#{(cents.abs % 100).to_s.rjust(2, '0')} €"
  end

  # An amount as typed into the form: decimal comma, no thousands separator.
  def self.typed(minor : Int64, currency : String) : String
    decimals = DECIMALS[currency]? || 2
    return minor.to_s if decimals == 0
    "#{minor // 10**decimals},#{(minor % 10**decimals).to_s.rjust(decimals, '0')}"
  end

  def self.german(date : String) : String
    y, m, d = date.split('-')
    "#{d}.#{m}.#{y}"
  end
end

describe "Seed invariants" do
  world = E2E.seeded_world
  ledger = uninitialized Ledger
  anna = uninitialized E2E::User
  today = E2E::DEFAULT_NOW[0, 10]

  before_all do
    ledger = Ledger.new(world.app.db_path)
    anna = world.user
    anna.login("Anna")
  end

  scenario "the database is consistent", world do
    E2E::Database.open(world.app.db_path) do |db|
      db.scalar("PRAGMA integrity_check").should eq "ok"
      db.query_all("PRAGMA foreign_key_check", as: {String, Int64?, String, Int64}).should be_empty
      db.scalar("SELECT count(*) FROM recurring WHERE active = 1 AND next_date <= ?", today).should eq 0
    end
  end

  scenario "the shares of every expense add up to its amount", world do
    ledger.expenses.size.should be > 800
    ledger.expenses.each do |e|
      sum = e.shares.values.sum
      {e.id, sum}.should eq({e.id, e.amount})
      case e.mode
      when "equal"
        (e.shares.values.max - e.shares.values.min).should be <= 1
      when "percent"
        E2E::Database.count(world.app.db_path, "SELECT sum(weight) FROM expense_shares WHERE expense_id = #{e.id}").should eq 10_000
      end
    end
    ledger.expenses.map(&.mode).uniq!.sort!.should eq %w(amount equal percent shares)
  end

  scenario "foreign amounts convert with the published or the manual rate", world do
    foreign = ledger.expenses.reject { |e| e.currency == "EUR" }
    foreign.map(&.currency).uniq!.sort!.should eq %w(CHF GBP IDR JPY KWD THB USD)
    foreign.each do |e|
      decimals = Ledger::DECIMALS[e.currency]? || 2
      cents = (e.minor.to_f / (10.0 ** decimals) / e.rate * 100).round(:ties_away).to_i64
      {e.id, e.amount}.should eq({e.id, cents})

      case e.source
      when "ezb"
        day = Time.parse_utc(Math.min(e.date, e.updated_at[0, 10]), "%Y-%m-%d")
        until E2E::FakeECB.business_day?(day)
          day -= 1.day
        end
        {e.id, e.rate}.should eq({e.id, world.ecb.rate(e.currency, day).to_f})
      when "manuell"
        manual = E2E::Database.open(world.app.db_path) do |db|
          db.query_all("SELECT rate FROM fx_rates WHERE source = 'manuell' AND currency = ? AND date <= ? ORDER BY date DESC LIMIT 1",
            e.currency, e.date, as: Float64)
        end
        {e.id, manual.includes?(e.rate)}.should eq({e.id, true})
      else
        fail "expense #{e.id}: unexpected rate source #{e.source.inspect}"
      end
    end
    ledger.expenses.select { |e| e.currency == "EUR" }.each { |e| {e.id, e.rate, e.source}.should eq({e.id, 1.0, ""}) }
  end

  scenario "balances add up to zero and the balances page and its suggestions agree", world do
    balances = ledger.balances
    balances.values.sum.should eq 0

    shown = W.texts(anna.get("/salden"), %(//div[contains(@class, "balance-row")]))
    expected = ledger.people.select { |id, _| !ledger.archived.includes?(id) || balances[id] != 0 }.map do |id, name|
      "#{name}#{" (archiviert)" if ledger.archived.includes?(id)} #{Ledger.euro(balances[id])}"
    end
    shown.sort.should eq expected.sort

    left = balances.dup
    anna.get("/salden").doc.xpath_nodes(%(//div[@class="transfer"]//a)).each do |link|
      params = URI.parse(link["href"]).query_params
      cents = params["betrag"].to_i64
      left[params["von"].to_i64] += cents
      left[params["an"].to_i64] -= cents
    end
    left.values.uniq!.should eq [0]
  end

  scenario "the home page lists every live expense once, newest first, with each person's balance", world do
    live = ledger.listed
    path = "/"
    seen = [] of String
    100.times do
      page = anna.get(path)
      page.status.should eq 200
      seen = page.doc.xpath_nodes(%(//a[starts-with(@id, "ausgabe-")])).map(&.["id"].lchop("ausgabe-"))
      link = page.doc.xpath_node("//a[@data-more]").try(&.["href"])
      break unless link
      path = link
    end
    seen.should eq live.map(&.id.to_s)

    ledger.people.each do |id, name|
      next if ledger.archived.includes?(id)
      user = world.user
      user.login(name).status.should eq 303
      page = user.get("/")
      rows = page.doc.xpath_nodes(%(//a[starts-with(@id, "ausgabe-")]))
      rows.size.should eq 100
      rows.zip(live).each do |row, e|
        involved = e.paid_by == id || e.shares.has_key?(id)
        balance = (e.paid_by == id ? e.amount : 0_i64) - (e.shares[id]? || 0_i64)
        metas = row.xpath_nodes(%(.//span[@class="expense-meta"])).map { |m| W.squish(m.content) }
        {name, e.id, metas[1]}.should eq({name, e.id, involved ? "Dein Saldo: #{Ledger.euro(balance)}" : "Du bist nicht beteiligt"})
      end
    end
  end

  scenario "every expense page shows what is stored", world do
    ledger.expenses.each do |e|
      page = anna.get("/ausgaben/#{e.id}")
      page.status.should eq 200
      if e.deleted
        page.text.should contain "Gelöschte Ausgabe"
        next
      end
      listed = %w(EUR USD GBP CHF DKK SEK NOK PLN CZK HUF TRY JPY CAD AUD).includes?(e.currency)
      shown = {
        W.input(page, "titel"), W.input(page, "datum"), W.selected(page, "bezahlt_von"), W.selected(page, "aufteilung"),
        W.selected(page, "waehrung"), W.input(page, "waehrung_andere"), W.input(page, "betrag"),
        page.doc.xpath_node(%(//textarea[@name="notiz"])).try(&.content), W.checked(page).sort,
        !page.doc.xpath_node(%(//input[@name="rueckzahlung"][@checked])).nil?,
      }
      shown.should eq({
        e.title, e.date, e.paid_by.to_s, e.mode, listed ? e.currency : "", listed ? "" : e.currency,
        Ledger.typed(e.minor, e.currency), e.notes, e.shares.keys.map(&.to_s).sort, e.reimbursement,
      })
      page.doc.xpath_nodes(%(//div[@class="split-row"])).map { |row| {row["data-id"].to_i64, W.squish(row.xpath_node(%(.//*[@data-share])).try(&.content) || "")} }
        .reject { |_, share| share.empty? }.to_h
        .should eq e.shares.transform_values { |cents| Ledger.euro(cents) }
    end
  end

  scenario "the exports hold exactly the live expenses", world do
    live = ledger.chronological
    deleted_ids = ledger.expenses.select(&.deleted).map(&.id)
    deleted_ids.should_not be_empty

    csv = CSV.parse(anna.get("/export/ausgaben.csv").body.lchop('﻿'), separator: ';')
    head, rows = csv.first, csv[1..]
    columns = head.each_with_index.to_h
    participants = head.select(&.starts_with?("Anteil ")).map { |h| {h, ledger.people.key_for(h.lchop("Anteil "))} }
    rows.map { |r| r[columns["ID"]].to_i64 }.should eq live.map(&.id)
    rows.zip(live).each do |row, e|
      cents = ->(text : String) { text.delete('.').sub(',', "").to_i64 }
      shares = participants.compact_map { |h, id| (cell = row[columns[h]]).empty? ? nil : {id, cents.call(cell)} }.to_h
      {
        row[columns["Datum"]], row[columns["Titel"]], row[columns["Bezahlt von"]], cents.call(row[columns["Betrag (EUR)"]]),
        row[columns["Währung"]], row[columns["Art"]], shares,
      }.should eq({
        Ledger.german(e.date), e.title, ledger.people[e.paid_by], e.amount, e.currency,
        e.reimbursement ? "Rückzahlung" : "Ausgabe", e.shares,
      })
    end

    json = anna.get("/export/ausgaben.json").json
    json["expenses"].as_a.map(&.["id"].as_i64).should eq live.map(&.id)
    json["expenses"].as_a.zip(live).each do |entry, e|
      shares = entry["shares"].as_a.to_h { |s| {s["participant_id"].as_i64, s["amount_cents"].as_i64} }
      {
        entry["date"].as_s, entry["title"].as_s, entry["paid_by"].as_i64, entry["amount_cents"].as_i64, entry["original_currency"].as_s,
        entry["original_amount_minor"].as_i64, entry["is_reimbursement"].as_bool, entry["split_mode"].as_s, shares,
      }.should eq({e.date, e.title, e.paid_by, e.amount, e.currency, e.minor, e.reimbursement, e.mode, e.shares})
    end
    json["participants"].as_a.to_h { |p| {p["id"].as_i64, p["name"].as_s} }.should eq ledger.people
  end

  scenario "the YNAB fake holds exactly the transactions selected for the connected person", world do
    config = E2E::Database.open(world.app.db_path) do |db|
      db.query_all("SELECT participant_id, account_id, start_date, connected_at FROM ynab_config WHERE account_id != ''",
        as: {Int64, String, String, String})
    end
    config.size.should eq 1
    person, account, start, connected = config.first
    mapping = E2E::Database.open(world.app.db_path) do |db|
      db.query_all("SELECT category_id, ynab_category_id FROM ynab_category_map WHERE participant_id = ?", person, as: {Int64, String}).to_h
    end

    expected = ledger.live.compact_map do |e|
      share = e.shares[person]? || 0_i64
      next if e.reimbursement || share <= 0 || e.date > today
      next unless e.date >= start || e.created_at >= connected
      {e.id, {account, e.date, -share * 10, e.title, e.category_id.try { |c| mapping[c]? }}}
    end.to_h
    expected.size.should be > 50

    live = world.app.ynab.live
    actual = live.to_h do |t|
      id = t.memo.not_nil!.match(/zipfelkasse #(\d+)\z/).not_nil![1].to_i64
      {id, {t.account_id, t.date, t.amount, t.payee_name, t.category_id}}
    end
    live.size.should eq actual.size
    actual.should eq expected

    E2E::Database.open(world.app.db_path) do |db|
      db.query_all("SELECT expense_id, ynab_txn_id FROM ynab_sync WHERE participant_id = ? AND ynab_txn_id != ''", person, as: {Int64, String}).to_h
        .should eq live.to_h { |t| {t.memo.not_nil!.match(/zipfelkasse #(\d+)\z/).not_nil![1].to_i64, t.id} }
      db.scalar("SELECT count(*) FROM ynab_sync WHERE last_error != '' OR participant_id != ?", person).should eq 0
    end
  end

  scenario "the activity log is complete and the activity page shows all of it", world do
    E2E::Database.open(world.app.db_path) do |db|
      created = db.query_all("SELECT expense_id FROM activity WHERE action = 'expense_created' ORDER BY expense_id", as: Int64)
      created.should eq ledger.expenses.map(&.id)
      db.query_all("SELECT expense_id FROM activity WHERE action = 'expense_deleted' ORDER BY expense_id", as: Int64)
        .should eq ledger.expenses.select(&.deleted).map(&.id)
      total = db.scalar("SELECT count(*) FROM activity").as(Int64)

      path = "/aktivitaet"
      entries = 0
      100.times do
        page = anna.get(path)
        page.status.should eq 200
        entries += page.doc.xpath_nodes(%(//*[contains(@class, "activity-main")])).size
        link = page.doc.xpath_node(%(//a[contains(@href, "vor=")])).try(&.["href"])
        break unless link
        path = link
      end
      entries.should eq total
    end
  end
end
