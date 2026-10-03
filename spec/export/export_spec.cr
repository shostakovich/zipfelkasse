require "../web/web_helper"
require "csv"

private alias Store = Zipfelkasse::Store
private alias Domain = Zipfelkasse::Domain
private alias Export = Zipfelkasse::Export
private alias YNAB = Zipfelkasse::YNAB

private STAMP   = Time.utc(2026, 9, 1, 10, 0, 0)
private ANNA    = Store::Participant.new(1_i64, "Anna", STAMP, nil)
private BEN     = Store::Participant.new(2_i64, "Ben", STAMP, nil)
private JUERGEN = Store::Participant.new(3_i64, "Jürgen", STAMP, nil)
private CLEO    = Store::Participant.new(4_i64, "Cleo", STAMP, date("2026-01-01")) # not involved anywhere
private PEOPLE  = [ANNA, BEN, CLEO, JUERGEN]

private def sh(p : Store::Participant, cents : Int64) : Domain::Share
  Domain::Share.new(p.id, 1_i64, cents)
end

private def eur(id : Int64, title : String, d : String, cents : Int64, cat : Int64, cat_name : String,
                payer : Store::Participant, *shares : Domain::Share) : Store::Expense
  input = Store::ExpenseInput.new(title: title, date: date(d), category_id: cat.zero? ? nil : cat, paid_by: payer.id,
    split_mode: Domain::SplitMode::Equal, amount_cents: cents, original_amount_minor: cents, original_currency: "EUR",
    fx_rate: 1.0, parts: shares.map { |s| Domain::Part.new(s.participant_id, s.weight) }.to_a)
  build_expense(id, input, shares.to_a, cat_name.presence, payer.name, STAMP)
end

# The block changes the input the expense was built from.
private def edit(e : Store::Expense, & : Store::ExpenseInput -> Store::ExpenseInput) : Store::Expense
  build_expense(e.id, yield(e.to_input), e.shares, e.category_name, e.paid_by_name, e.created_at)
end

# Chronological.
private def sample : Array(Store::Expense)
  cafe = eur(1, "Café & Kuchen", "2026-09-01", 1201, 2, "Restaurant", ANNA, sh(ANNA, 601), sh(JUERGEN, 600))
  cafe = edit(cafe) { |i| i.notes = "lecker; „süß“"; i }
  diner = eur(2, %(Diner "NYC"), "2026-09-03", 8000, 0, "", BEN, sh(ANNA, 4000), sh(BEN, 4000))
  diner = edit(diner) do |i|
    i.original_amount_minor, i.original_currency, i.fx_rate, i.fx_source = 9000_i64, "USD", 1.125, Domain::FXSource::Ecb
    i.recurring_id = 7_i64
    i
  end
  back = eur(3, "Rückzahlung", "2026-09-05", 600, 0, "", JUERGEN, sh(ANNA, 600))
  back = edit(back) { |i| i.reimbursement = true; i }
  formula = eur(4, "=SUMME(A1)", "2026-09-10", 500, 1, "Lebensmittel", BEN, sh(BEN, 500))
  [cafe, diner, back, formula]
end

private def sample_postings : Array(YNAB::Posting)
  YNAB::Selection.new(date("2026-10-02")).postings(sample, ANNA.id)
end

private class Fixture
  getter srv = TestServer.new
  getter anna : Int64
  getter juer : Int64

  def initialize
    @anna = st.create_participant(nil, "Anna")
    @juer = st.create_participant(nil, "Jürgen")
    add("Brötchen", "2026-08-30", 400, juer, anna, juer)
    add("Käse", "2026-09-02", 1000, juer, anna, juer)
    gone = add("Gelöscht", "2026-09-03", 999, anna, anna, juer)
    st.delete_expense(anna, gone)
    add("Nur Jürgen", "2026-09-04", 700, juer, juer)
  end

  def st : Store
    srv.store
  end

  def input(title : String, d : Time, cents : Int64, payer : Int64, *who : Int64) : Store::ExpenseInput
    Store::ExpenseInput.new(title: title, date: d, paid_by: payer, split_mode: Domain::SplitMode::Equal,
      amount_cents: cents, parts: who.map { |id| Domain::Part.new(id) }.to_a)
  end

  def add(title : String, d : String, cents : Int64, payer : Int64, *who : Int64) : Int64
    st.create_expense(payer, input(title, date(d), cents, payer, *who))
  end

  def get(path : String) : HTTP::Client::Response
    srv.get(path, who_cookie(anna))
  end
end

private def with_fixture(&)
  f = Fixture.new
  begin
    yield f
  ensure
    f.srv.close
  end
end

describe Zipfelkasse::Export do
  it "writes the expenses CSV in the German Excel format" do
    io = IO::Memory.new
    Export.write_expenses_csv(io, PEOPLE, sample)
    io.to_s.should start_with Export::BOM
    CSV.parse(io.to_s.lchop(Export::BOM), separator: ';').should eq [
      ["ID", "Datum", "Titel", "Kategorie", "Bezahlt von", "Betrag (EUR)", "Originalbetrag", "Währung", "Kurs", "Art", "Aufteilung",
       "Notiz", "Anteil Anna", "Anteil Ben", "Anteil Jürgen"],
      ["1", "01.09.2026", "Café & Kuchen", "Restaurant", "Anna", "12,01", "12,01", "EUR", "", "Ausgabe", "Gleichmäßig", "lecker; „süß“", "6,01", "", "6,00"],
      ["2", "03.09.2026", %(Diner "NYC"), "", "Ben", "80,00", "90,00", "USD", "1,125", "Ausgabe", "Gleichmäßig", "", "40,00", "40,00", ""],
      ["3", "05.09.2026", "Rückzahlung", "", "Jürgen", "6,00", "6,00", "EUR", "", "Rückzahlung", "Gleichmäßig", "", "6,00", "", ""],
      ["4", "10.09.2026", "'=SUMME(A1)", "Lebensmittel", "Ben", "5,00", "5,00", "EUR", "", "Ausgabe", "Gleichmäßig", "", "", "5,00", ""],
    ]
  end

  it "defuses formulas and keeps multi-line notes in the CSV" do
    e = edit(sample[0]) do |i|
      i.title = %(=Formel <&> "q")
      i.notes = "Zeile1\r\nZeile2\nZeile3; x"
      i
    end
    io = IO::Memory.new
    Export.write_expenses_csv(io, PEOPLE, [e])
    row = CSV.parse(io.to_s.lchop(Export::BOM), separator: ';')[1]
    {row[2], row[11]}.should eq({"'=Formel <&> \"q\"", "Zeile1\r\nZeile2\nZeile3; x"})
    io = IO::Memory.new
    Export.write_expenses_csv(io, PEOPLE, [] of Store::Expense)
    CSV.parse(io.to_s.lchop(Export::BOM), separator: ';').map(&.size).should eq [12]
  end

  it "writes the expenses JSON" do
    io = IO::Memory.new
    now = Time.utc(2026, 10, 2, 12, 0, 0)
    Export.write_expenses_json(io, "WG Süd", now, Export::Period.new(from: date("2026-09-01")), PEOPLE[0, 2], sample[1, 1])
    JSON.parse(io.to_s).should eq JSON.parse(<<-JSON)
      {
        "group": "WG Süd",
        "exported_at": "2026-10-02T12:00:00Z",
        "from": "2026-09-01",
        "currency": "EUR",
        "participants": [
          {
            "id": 1,
            "name": "Anna",
            "archived": false
          },
          {
            "id": 2,
            "name": "Ben",
            "archived": false
          }
        ],
        "expenses": [
          {
            "id": 2,
            "date": "2026-09-03",
            "title": "Diner \\"NYC\\"",
            "category_id": null,
            "category": "",
            "paid_by": 2,
            "paid_by_name": "Ben",
            "amount_cents": 8000,
            "is_reimbursement": false,
            "split_mode": "equal",
            "original_amount_minor": 9000,
            "original_currency": "USD",
            "fx_rate": 1.125,
            "fx_source": "ezb",
            "notes": "",
            "recurring_id": 7,
            "shares": [
              {
                "participant_id": 1,
                "name": "Anna",
                "weight": 1,
                "amount_cents": 4000
              },
              {
                "participant_id": 2,
                "name": "Ben",
                "weight": 1,
                "amount_cents": 4000
              }
            ],
            "created_at": "2026-09-01T10:00:00Z",
            "updated_at": "2026-09-01T10:00:00Z"
          }
        ]
      }
      JSON
  end

  it "leaves out the range of an unbounded export" do
    io = IO::Memory.new
    Export.write_expenses_json(io, "G", Time.utc(2026, 10, 3, 6, 14, 49), Export::Period.new, [] of Store::Participant, sample[0, 1])
    json = JSON.parse(io.to_s)
    {json["exported_at"], json["category_id"]?, json["expenses"][0]["category_id"], json["expenses"][0]["fx_rate"]}
      .should eq({"2026-10-03T06:14:49Z", nil, 2, 1})
    json.as_h.has_key?("from").should be_false
  end

  it "selects the same postings as the YNAB sync" do
    # The reimbursement is missing, expense 4 has no share of Anna.
    sample_postings.map(&.expense_id).should eq [1, 2]
  end

  it "writes OFX" do
    io = IO::Memory.new
    Export.write_ofx(io, sample_postings, "ZIPFELKASSE-1", nil, nil, Time.utc(2026, 10, 2, 12, 30, 0))
    io.to_s.should eq <<-OFX.gsub("\n", "\r\n") + "\r\n"
      OFXHEADER:100
      DATA:OFXSGML
      VERSION:102
      SECURITY:NONE
      ENCODING:UTF-8
      CHARSET:NONE
      COMPRESSION:NONE
      OLDFILEUID:NONE
      NEWFILEUID:NONE

      <OFX>
      <SIGNONMSGSRSV1>
      <SONRS>
      <STATUS>
      <CODE>0
      <SEVERITY>INFO
      </STATUS>
      <DTSERVER>20261002123000
      <LANGUAGE>GER
      </SONRS>
      </SIGNONMSGSRSV1>
      <BANKMSGSRSV1>
      <STMTTRNRS>
      <TRNUID>1
      <STATUS>
      <CODE>0
      <SEVERITY>INFO
      </STATUS>
      <STMTRS>
      <CURDEF>EUR
      <BANKACCTFROM>
      <BANKID>ZIPFEL
      <ACCTID>ZIPFELKASSE-1
      <ACCTTYPE>CHECKING
      </BANKACCTFROM>
      <BANKTRANLIST>
      <DTSTART>20260901
      <DTEND>20260903
      <STMTTRN>
      <TRNTYPE>DEBIT
      <DTPOSTED>20260901
      <TRNAMT>-6.01
      <FITID>zipfelkasse-1
      <NAME>Café &amp; Kuchen
      <MEMO>Gesamt 12,01 € · bezahlt von Anna · zipfelkasse #1
      </STMTTRN>
      <STMTTRN>
      <TRNTYPE>DEBIT
      <DTPOSTED>20260903
      <TRNAMT>-40.00
      <FITID>zipfelkasse-2
      <NAME>Diner "NYC"
      <MEMO>Gesamt 80,00 € (90,00 USD) · bezahlt von Ben · zipfelkasse #2
      </STMTTRN>
      </BANKTRANLIST>
      <LEDGERBAL>
      <BALAMT>-46.01
      <DTASOF>20260903
      </LEDGERBAL>
      </STMTRS>
      </STMTTRNRS>
      </BANKMSGSRSV1>
      </OFX>
      OFX
  end

  it "cuts OFX fields before escaping and uses an explicit period" do
    ps = [YNAB::Posting.new(9_i64, date("2026-09-02"), 5_i64, "Sehr langer Titel mit <Sonderzeichen> und Überlänge",
      "Zeile 1\nZeile 2", 0_i64)]
    io = IO::Memory.new
    Export.write_ofx(io, ps, "X", date("2026-09-01"), date("2026-09-30"), STAMP)
    {"<NAME>Sehr langer Titel mit &lt;Sonderzei\r\n", "<MEMO>Zeile 1 Zeile 2\r\n", "<TRNAMT>-0.05\r\n",
     "<DTSTART>20260901\r\n", "<DTEND>20260930\r\n"}.each { |want| io.to_s.should contain want }
  end

  it "writes the YNAB CSV" do
    io = IO::Memory.new
    Export.write_ynab_csv(io, sample_postings)
    io.to_s.should eq "Date,Payee,Memo,Outflow,Inflow\n" \
                      "2026-09-01,Café & Kuchen,\"Gesamt 12,01 € · bezahlt von Anna · zipfelkasse #1\",6.01,\n" \
                      "2026-09-03,\"Diner \"\"NYC\"\"\",\"Gesamt 80,00 € (90,00 USD) · bezahlt von Ben · zipfelkasse #2\",40.00,\n"
  end

  it "defuses formulas in the YNAB CSV" do
    ps = [YNAB::Posting.new(1_i64, date("2026-09-01"), 100_i64, %(=HYPERLINK("x")), "+1 · zipfelkasse #1", 0_i64)]
    io = IO::Memory.new
    Export.write_ynab_csv(io, ps)
    io.to_s.should contain %("'=HYPERLINK(""x"")")
    io.to_s.should contain "'+1 · zipfelkasse #1"
  end

  it "shows the export page and rejects invalid periods" do
    with_fixture do |f|
      res = f.get("/export?von=2026-09-01")
      res.status_code.should eq 200
      res.body.should contain %(formaction="/export/ynab.ofx")
      res.body.should contain %(value="2026-09-01")
      f.get("/export?von=garbage").status_code.should eq 422
      res = f.get("/export/ausgaben.csv?von=2026-09-10&bis=2026-09-01")
      res.status_code.should eq 422
      res.body.should contain "„Bis“ liegt vor „Von“"
      res.body.should contain "alert-destructive"
    end
  end

  it "downloads all expenses" do
    with_fixture do |f|
      res = f.get("/export/ausgaben.csv?von=01.09.2026&bis=2026-09-30")
      res.status_code.should eq 200
      res.headers["Content-Disposition"].should eq %(attachment; filename="zipfelkasse-ausgaben-2026-09-01_2026-09-30.csv")
      res.headers["Content-Type"].should eq "text/csv; charset=utf-8"
      res.headers["Cache-Control"].should eq "no-store"
      res.headers["Content-Length"].should eq res.body.bytesize.to_s
      body = res.body
      body.should start_with "﻿ID;"
      body.should contain ";Käse;"
      body.should_not contain "Brötchen"
      body.should_not contain "Gelöscht"
      body.index!("Käse").should be < body.index!("Nur Jürgen")

      res = f.get("/export/ausgaben.json")
      res.status_code.should eq 200
      res.headers["Content-Disposition"].should start_with %(attachment; filename="zipfelkasse-ausgaben-)
      out = JSON.parse(res.body)
      out["expenses"].size.should eq 3
      out["expenses"][0]["title"].should eq "Brötchen"
      out["participants"].size.should eq 2
      out["from"]?.should be_nil
    end
  end

  it "downloads my postings for YNAB" do
    with_fixture do |f|
      res = f.get("/export/ynab.ofx?von=2026-09-01")
      res.status_code.should eq 200
      res.headers["Content-Type"].should eq "application/x-ofx"
      res.headers["Content-Disposition"].should eq %(attachment; filename="zipfelkasse-ynab-ab-2026-09-01.ofx")
      body = res.body
      # Only Anna's share of "Käse" (Brötchen before the range, deleted and "Nur Jürgen" without a share).
      body.scan("<STMTTRN>").size.should eq 1
      body.should contain "<NAME>Käse\r\n"
      body.should contain "<TRNAMT>-5.00\r\n"
      body.should contain "<ACCTID>ZIPFELKASSE-#{f.anna}\r\n"
      res = f.get("/export/ynab.csv")
      res.status_code.should eq 200
      res.body.should eq "Date,Payee,Memo,Outflow,Inflow\n" \
                         "2026-08-30,Brötchen,\"Gesamt 4,00 € · bezahlt von Jürgen · zipfelkasse #1\",2.00,\n" \
                         "2026-09-02,Käse,\"Gesamt 10,00 € · bezahlt von Jürgen · zipfelkasse #2\",5.00,\n"
    end
  end

  it "writes nothing to the database" do
    with_fixture do |f|
      f.st.set_ynab_token(f.anna, "tok")
      f.st.set_ynab_target(f.anna, Store::YNABTarget.new("p", "a", start: date("2026-09-01")))
      f.st.db.exec("UPDATE ynab_config SET connected_at = NULL")
      f.get("/export/ynab.csv").status_code.should eq 200
      f.st.get_ynab_config(f.anna).connected_at.should be_nil
    end
  end

  it "contains exactly what the YNAB sync transfers" do
    with_fixture do |f|
      # Without YNAB: all past expenses, no future ones.
      future = f.input("Zukunft", Domain.date_of(Time.utc.shift(days: 3)), 800, f.juer, f.anna, f.juer)
      f.st.create_expense(f.juer, future)
      body = f.get("/export/ynab.csv").body
      body.should_not contain "Zukunft"
      body.should contain "Brötchen"

      # With YNAB from Sep 1: Brötchen (Aug 30, entered before the setup) is
      # missing, an expense entered afterwards with an earlier date is included.
      clock = Time.utc + 1.hour
      f.st.clock = -> { clock }
      f.st.set_ynab_token(f.anna, "tok", nil)
      f.st.set_ynab_target(f.anna, Store::YNABTarget.new("p", "a", start: date("2026-09-01")))
      clock += 1.minute
      f.st.create_expense(f.juer, f.input("Nachgetragen", date("2026-08-15"), 600, f.juer, f.anna, f.juer))
      body = f.get("/export/ynab.csv").body
      body.should contain "Nachgetragen"
      body.should contain "Käse"
      body.should_not contain "Brötchen"
      body.should_not contain "Zukunft"

      # Already in YNAB: stays included; the range filters additionally.
      f.st.put_ynab_sync(Store::YNABSync.new(1_i64, f.anna, "t1", "h"))
      f.get("/export/ynab.csv").body.should contain "Brötchen"
      body = f.get("/export/ynab.ofx?von=2026-09-01").body
      body.scan("<STMTTRN>").size.should eq 1
      body.should contain "<NAME>Käse"
    end
  end
end
