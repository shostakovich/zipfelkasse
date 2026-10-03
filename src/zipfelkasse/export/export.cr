# Downloads: all expenses as CSV/JSON, and one's own shares as OFX/CSV for
# the YNAB file import. The YNAB files contain exactly the transactions the
# YNAB sync writes too (YNAB::Selection).
module Zipfelkasse::Export
  # The optional date range (?von=…&bis=…, both inclusive).
  record Period, from : Time? = nil, to : Time? = nil do
    def self.parse(r : Web::Request) : Period
      from = date_param(r, "von")
      to = date_param(r, "bis")
      if from && to && to < from
        raise Domain::ValidationError.new("„Bis“ liegt vor „Von“.")
      end
      new(from, to)
    end

    # Only an empty value means unset; blanks are an invalid date.
    private def self.date_param(r : Web::Request, name : String) : Time?
      v = r.query(name)
      Domain.parse_date(v) unless v.empty?
    end

    # For file names: the date range or today's date.
    def suffix(today : Time) : String
      from, to = @from, @to
      if from && to
        "#{Store.format_date(from)}_#{Store.format_date(to)}"
      elsif from
        "ab-#{Store.format_date(from)}"
      elsif to
        "bis-#{Store.format_date(to)}"
      else
        Store.format_date(today)
      end
    end
  end

  class Handlers
    include Web::Helpers

    def initialize(@d : Web::Deps)
    end

    def register : Nil
      Web.route(@d, "GET", "/export") { |r| page(r) }
      Web.route(@d, "GET", "/export/ausgaben.csv") { |r| expenses_csv(r) }
      Web.route(@d, "GET", "/export/ausgaben.json") { |r| expenses_json(r) }
      Web.route(@d, "GET", "/export/ynab.ofx") { |r| ynab_ofx(r) }
      Web.route(@d, "GET", "/export/ynab.csv") { |r| ynab_csv(r) }
    end

    private def render(r : Web::Request, status : Int32, error : String, period : Period) : Nil
      r.page(status, Web::Page.new(title: "Export", nav: Web::NAV_SETTINGS, error: error)) do |__io__|
        Web.template __io__, "export/export.ecr"
      end
    end

    # Every route answers an invalid range with the page (422, empty fields).
    private def period(r : Web::Request) : Period?
      Period.parse(r)
    rescue ex : Domain::ValidationError
      render(r, 422, ex.msg, Period.new)
      nil
    end

    private def page(r : Web::Request) : Nil
      p = period(r) || return
      render(r, 200, "", p)
    end

    # Non-deleted expenses in the range, oldest first.
    private def expenses(p : Period, participant_id : Int64) : Array(Store::Expense)
      @d.store.list_expenses(Store::ExpenseFilter.new(from: p.from, to: p.to, participant_id: participant_id)).reverse!
    end

    private def send(r : Web::Request, content_type : String, filename : String, body : String) : Nil
      res = r.response
      res.headers["Content-Type"] = content_type
      res.headers["Content-Disposition"] = %(attachment; filename="#{filename}")
      res.headers["Cache-Control"] = "no-store"
      res.content_length = body.bytesize
      res.print body
    end

    private def expenses_csv(r : Web::Request) : Nil
      p = period(r) || return
      es = expenses(p, 0_i64)
      body = String.build { |io| Export.write_expenses_csv(io, @d.store.list_participants(true), es) }
      send(r, "text/csv; charset=utf-8", "zipfelkasse-ausgaben-#{p.suffix(@d.today)}.csv", body)
    end

    private def expenses_json(r : Web::Request) : Nil
      p = period(r) || return
      es = expenses(p, 0_i64)
      body = String.build do |io|
        Export.write_expenses_json(io, @d.store.group_name, @d.now, p, @d.store.list_participants(true), es)
      end
      send(r, "application/json; charset=utf-8", "zipfelkasse-ausgaben-#{p.suffix(@d.today)}.json", body)
    end

    # My postings in the range, selected like the YNAB sync does (start date,
    # entered later, already transferred, nothing in the future).
    private def postings(r : Web::Request, p : Period) : Array(YNAB::Posting)
      me = r.me.id
      sel = YNAB::Selection.for_participant(@d.store, me, YNAB.today(@d.now, @d.config.location))
      sel.postings(expenses(p, me), me)
    end

    private def ynab_ofx(r : Web::Request) : Nil
      p = period(r) || return
      ps = postings(r, p)
      body = String.build do |io|
        Export.write_ofx(io, ps, "ZIPFELKASSE-#{r.me.id}", p.from, p.to, @d.now.in(@d.config.location))
      end
      send(r, "application/x-ofx", "zipfelkasse-ynab-#{p.suffix(@d.today)}.ofx", body)
    end

    private def ynab_csv(r : Web::Request) : Nil
      p = period(r) || return
      body = String.build { |io| Export.write_ynab_csv(io, postings(r, p)) }
      send(r, "text/csv; charset=utf-8", "zipfelkasse-ynab-#{p.suffix(@d.today)}.csv", body)
    end
  end
end

module Zipfelkasse
  class App
    def self.wire_export(app : App, d : Web::Deps, mcp : Web::MCPMount) : Nil
      Export::Handlers.new(d).register
    end
  end
end
