require "csv"
require "ecr"
require "json"

module Zipfelkasse::Export
  BOM = '\u{FEFF}'

  # For German Excel: UTF-8 with BOM, semicolons and decimal commas.
  def self.write_expenses_csv(io : IO, people : Array(Store::Participant), es : Array(Store::Expense)) : Nil
    io << BOM
    people = involved(people, es)
    CSV.build(io, separator: ';') do |csv|
      csv.row ["ID", "Datum", "Titel", "Kategorie", "Bezahlt von", "Betrag (EUR)", "Originalbetrag", "Währung",
               "Kurs", "Art", "Aufteilung", "Notiz"] + people.map { |p| "Anteil #{p.name}" }
      es.each do |e|
        csv.row [
          e.id.to_s,
          Domain.format_date(e.date),
          cell(e.title),
          cell(e.category_name || ""),
          cell(e.paid_by_name),
          Domain.format_decimal(e.amount_cents, 2, ','),
          Domain.format_decimal(e.original_amount_minor, Domain.currency_decimals(e.original_currency), ','),
          e.original_currency,
          e.foreign? ? Domain.format_rate(e.fx_rate) : "",
          e.reimbursement? ? Domain::REIMBURSEMENT_TITLE : "Ausgabe",
          Web.split_mode_label(e.split_mode),
          cell(e.notes),
        ] + people.map { |p| e.shares.any?(&.participant_id.==(p.id)) ? Domain.format_decimal(e.share_of(p.id), 2, ',') : "" }
      end
    end
  end

  private def self.involved(people : Array(Store::Participant), es : Array(Store::Expense)) : Array(Store::Participant)
    seen = Set(Int64).new
    es.each do |e|
      seen << e.paid_by
      e.shares.each { |s| seen << s.participant_id }
    end
    people.select { |p| seen.includes?(p.id) }
  end

  def self.cell(s : String) : String
    s.starts_with?(/[=+\-@\t\r]/) ? "'" + s : s
  end

  def self.write_expenses_json(io : IO, group : String, now : Time, p : Period,
                               people : Array(Store::Participant), es : Array(Store::Expense)) : Nil
    names = people.to_h { |person| {person.id, person.name} }
    JSON.build(io, indent: "  ") do |json|
      json.object do
        json.field "group", group
        json.field "exported_at", now.to_utc.to_rfc3339
        p.from.try { |t| json.field "from", Store.format_date(t) }
        p.to.try { |t| json.field "to", Store.format_date(t) }
        json.field "currency", "EUR"
        json.field "participants", people.map { |person| {id: person.id, name: person.name, archived: person.archived?} }
        json.field "expenses", es.map { |e| json_expense(e, names) }
      end
    end
    io << '\n'
  end

  private def self.json_expense(e : Store::Expense, names : Hash(Int64, String))
    {
      id:                    e.id,
      date:                  Store.format_date(e.date),
      title:                 e.title,
      category_id:           e.category_id,
      category:              e.category_name || "",
      paid_by:               e.paid_by,
      paid_by_name:          e.paid_by_name,
      amount_cents:          e.amount_cents,
      is_reimbursement:      e.reimbursement?,
      split_mode:            e.split_mode.to_s.underscore,
      original_amount_minor: e.original_amount_minor,
      original_currency:     e.original_currency,
      fx_rate:               e.fx_rate,
      fx_source:             e.fx_source.try(&.key) || "",
      notes:                 e.notes,
      recurring_id:          e.recurring_id,
      shares:                e.shares.map do |s|
        {participant_id: s.participant_id, name: names[s.participant_id]? || "", weight: s.weight, amount_cents: s.amount_cents}
      end,
      created_at: e.created_at.to_utc.to_rfc3339,
      updated_at: e.updated_at.to_utc.to_rfc3339,
    }
  end

  # OFX 1.02 (SGML) with CRLF line ends; without from or to, the range comes from the postings or now.
  def self.write_ofx(io : IO, ps : Array(YNAB::Posting), account_id : String, from : Time?, to : Time?, now : Time) : Nil
    from ||= ps.first?.try(&.date) || now
    to ||= ps.last?.try(&.date) || now
    total = ps.sum(0_i64) { |p| -p.amount_cents }
    statement = String.build { |s| ECR.embed "#{__DIR__}/statement.ofx.ecr", s }
    io << statement.gsub('\n', "\r\n")
  end

  def self.sgml(s : String, n : Int32) : String
    s = s.split.join(" ")
    s = s[0, n].strip if s.size > n
    s.gsub({'&' => "&amp;", '<' => "&lt;", '>' => "&gt;"})
  end

  def self.write_ynab_csv(io : IO, ps : Array(YNAB::Posting)) : Nil
    CSV.build(io) do |csv|
      csv.row "Date", "Payee", "Memo", "Outflow", "Inflow"
      ps.each do |p|
        csv.row Store.format_date(p.date), cell(p.payee), cell(p.memo), Domain.format_decimal(p.amount_cents, 2, '.'), ""
      end
    end
  end
end
