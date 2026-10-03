module Zipfelkasse::Export
  # German Excel format: UTF-8 with BOM, semicolon, decimal comma, CRLF, one
  # column "Anteil <Name>" per involved person. es is sorted chronologically.
  def self.write_expenses_csv(io : IO, people : Array(Store::Participant), es : Array(Store::Expense)) : Nil
    io << '﻿'
    people = involved(people, es)
    head = ["ID", "Datum", "Titel", "Kategorie", "Bezahlt von", "Betrag (EUR)", "Originalbetrag", "Währung",
            "Kurs", "Art", "Aufteilung", "Notiz"]
    people.each { |p| head << "Anteil #{p.name}" }
    csv_record(io, head, ';', crlf: true)
    es.each do |e|
      rec = [
        e.id.to_s,
        Domain.format_date(e.date),
        cell(e.title),
        cell(e.category_name),
        cell(e.paid_by_name),
        Domain.format_decimal(e.amount_cents, 2, ','),
        Domain.format_decimal(e.original_amount_minor, Domain.currency_decimals(e.original_currency), ','),
        e.original_currency,
        e.foreign? ? Domain.format_rate(e.fx_rate) : "",
        e.reimbursement? ? "Rückzahlung" : "Ausgabe",
        e.split_mode.label,
        cell(e.notes),
      ]
      people.each do |p|
        rec << (e.shares.any?(&.participant_id.==(p.id)) ? Domain.format_decimal(e.share_of(p.id), 2, ',') : "")
      end
      csv_record(io, rec, ';', crlf: true)
    end
  end

  # Those of people who pay or take part in es.
  private def self.involved(people : Array(Store::Participant), es : Array(Store::Expense)) : Array(Store::Participant)
    seen = Set(Int64).new
    es.each do |e|
      seen << e.paid_by
      e.shares.each { |s| seen << s.participant_id }
    end
    people.select { |p| seen.includes?(p.id) }
  end

  # Defuses text that spreadsheet programs would run as a formula (CSV
  # injection).
  def self.cell(s : String) : String
    s.empty? || !s.byte_at(0).unsafe_chr.in?('=', '+', '-', '@', '\t', '\r') ? s : "'" + s
  end

  # Quoting as common CSV readers expect: only when needed, never for an
  # empty field. With crlf, line breaks inside fields become CRLF too.
  protected def self.csv_record(io : IO, fields : Array(String), sep : Char, crlf : Bool) : Nil
    fields.each_with_index do |f, i|
      io << sep if i > 0
      unless csv_quote?(f, sep)
        io << f
        next
      end
      io << '"'
      f.each_byte do |b|
        case b
        when '"'.ord  then io << %("")
        when '\r'.ord then io.write_byte(b) unless crlf
        when '\n'.ord then io << (crlf ? "\r\n" : "\n")
        else               io.write_byte(b)
        end
      end
      io << '"'
    end
    io << (crlf ? "\r\n" : "\n")
  end

  private def self.csv_quote?(f : String, sep : Char) : Bool
    return false if f.empty?
    return true if f == "\\."
    f.each_byte { |b| return true if b.in?('\n'.ord, '\r'.ord, '"'.ord, sep.ord) }
    f[0].whitespace?
  end

  def self.write_expenses_json(io : IO, group : String, now : Time, p : Period,
                               people : Array(Store::Participant), es : Array(Store::Expense)) : Nil
    names = people.to_h { |pp| {pp.id, pp.name} }
    JSON.build(io, indent: "  ") do |j|
      j.object do
        j.field "group", group
        j.field "exported_at", json_time(now)
        p.from.try { |t| j.field "from", Store.format_date(t) }
        p.to.try { |t| j.field "to", Store.format_date(t) }
        j.field "currency", "EUR"
        j.field "participants" do
          j.array do
            people.each do |pp|
              j.object do
                j.field "id", pp.id
                j.field "name", pp.name
                j.field "archived", pp.archived?
              end
            end
          end
        end
        j.field "expenses" do
          j.array { es.each { |e| json_expense(j, e, names) } }
        end
      end
    end
    io << '\n'
  end

  private def self.json_expense(j : JSON::Builder, e : Store::Expense, names : Hash(Int64, String)) : Nil
    j.object do
      j.field "id", e.id
      j.field "date", Store.format_date(e.date)
      j.field "title", e.title
      j.field "category_id", e.category_id == 0 ? nil : e.category_id
      j.field "category", e.category_name
      j.field "paid_by", e.paid_by
      j.field "paid_by_name", e.paid_by_name
      j.field "amount_cents", e.amount_cents
      j.field "is_reimbursement", e.reimbursement?
      j.field "split_mode", e.split_mode.value
      j.field "original_amount_minor", e.original_amount_minor
      j.field "original_currency", e.original_currency
      # 1, not 1.0, for EUR.
      j.field "fx_rate" { e.fx_rate == e.fx_rate.trunc && e.fx_rate.abs < 1e15 ? j.number(e.fx_rate.to_i64) : j.number(e.fx_rate) }
      j.field "fx_source", e.fx_source
      j.field "notes", e.notes
      j.field "recurring_id", e.recurring_id == 0 ? nil : e.recurring_id
      j.field "shares" do
        j.array do
          e.shares.each do |s|
            j.object do
              j.field "participant_id", s.participant_id
              j.field "name", names[s.participant_id]? || ""
              j.field "weight", s.weight
              j.field "amount_cents", s.amount_cents
            end
          end
        end
      end
      j.field "created_at", json_time(e.created_at)
      j.field "updated_at", json_time(e.updated_at)
    end
  end

  # RFC 3339 in UTC with as many fraction digits as needed; nil is
  # 0001-01-01T00:00:00Z.
  private def self.json_time(t : Time?) : String
    t = (t || Domain::UNSET_TIME).to_utc
    s = t.to_s("%Y-%m-%dT%H:%M:%S")
    s += "." + t.nanosecond.to_s.rjust(9, '0').rstrip('0') if t.nanosecond > 0
    s + "Z"
  end

  # OFX 1.02 (SGML): a statement of the clearing account, UTF-8, CRLF. FITID
  # is stable per expense. Without from or to, the range comes from the
  # postings (or now, in its own time zone).
  def self.write_ofx(io : IO, ps : Array(YNAB::Posting), account_id : String, from : Time?, to : Time?, now : Time) : Nil
    lo, hi = ps.empty? ? {now, now} : {ps.first.date, ps.last.date}
    from ||= lo
    to ||= hi
    total = ps.sum(0_i64) { |p| -p.amount_cents }
    line = ->(s : String) { io << s << "\r\n" }
    line.call "OFXHEADER:100"
    line.call "DATA:OFXSGML"
    line.call "VERSION:102"
    line.call "SECURITY:NONE"
    line.call "ENCODING:UTF-8"
    line.call "CHARSET:NONE"
    line.call "COMPRESSION:NONE"
    line.call "OLDFILEUID:NONE"
    line.call "NEWFILEUID:NONE"
    line.call ""
    line.call "<OFX>"
    line.call "<SIGNONMSGSRSV1>"
    line.call "<SONRS>"
    line.call "<STATUS>"
    line.call "<CODE>0"
    line.call "<SEVERITY>INFO"
    line.call "</STATUS>"
    line.call "<DTSERVER>#{now.to_utc.to_s("%Y%m%d%H%M%S")}"
    line.call "<LANGUAGE>GER"
    line.call "</SONRS>"
    line.call "</SIGNONMSGSRSV1>"
    line.call "<BANKMSGSRSV1>"
    line.call "<STMTTRNRS>"
    line.call "<TRNUID>1"
    line.call "<STATUS>"
    line.call "<CODE>0"
    line.call "<SEVERITY>INFO"
    line.call "</STATUS>"
    line.call "<STMTRS>"
    line.call "<CURDEF>EUR"
    line.call "<BANKACCTFROM>"
    line.call "<BANKID>ZIPFEL" # OFX allows at most 9 characters
    line.call "<ACCTID>#{sgml(account_id, 22)}"
    line.call "<ACCTTYPE>CHECKING"
    line.call "</BANKACCTFROM>"
    line.call "<BANKTRANLIST>"
    line.call "<DTSTART>#{from.to_s("%Y%m%d")}"
    line.call "<DTEND>#{to.to_s("%Y%m%d")}"
    ps.each do |p|
      line.call "<STMTTRN>"
      line.call "<TRNTYPE>DEBIT"
      line.call "<DTPOSTED>#{p.date.to_s("%Y%m%d")}"
      line.call "<TRNAMT>#{Domain.format_decimal(-p.amount_cents, 2, '.')}"
      line.call "<FITID>zipfelkasse-#{p.expense_id}"
      line.call "<NAME>#{sgml(p.payee, 32)}"
      line.call "<MEMO>#{sgml(p.memo, 255)}"
      line.call "</STMTTRN>"
    end
    line.call "</BANKTRANLIST>"
    line.call "<LEDGERBAL>"
    line.call "<BALAMT>#{Domain.format_decimal(total, 2, '.')}"
    line.call "<DTASOF>#{to.to_s("%Y%m%d")}"
    line.call "</LEDGERBAL>"
    line.call "</STMTRS>"
    line.call "</STMTTRNRS>"
    line.call "</BANKMSGSRSV1>"
    line.call "</OFX>"
  end

  # Collapses whitespace (incl. line breaks), cuts to the OFX field length n
  # (characters) and then escapes &, < and >.
  def self.sgml(s : String, n : Int32) : String
    s = s.split.join(" ")
    s = s[0, n].strip if s.size > n
    s.gsub({'&' => "&amp;", '<' => "&lt;", '>' => "&gt;"})
  end

  # The CSV of the YNAB file import: ISO dates, amounts with a dot, comma,
  # LF, no BOM.
  def self.write_ynab_csv(io : IO, ps : Array(YNAB::Posting)) : Nil
    csv_record(io, ["Date", "Payee", "Memo", "Outflow", "Inflow"], ',', crlf: false)
    ps.each do |p|
      csv_record(io, [Store.format_date(p.date), cell(p.payee), cell(p.memo),
                      Domain.format_decimal(p.amount_cents, 2, '.'), ""], ',', crlf: false)
    end
  end
end
