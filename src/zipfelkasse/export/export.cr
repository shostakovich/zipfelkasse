module Zipfelkasse::Export
  # The optional date range (?von=…&bis=…, both inclusive).
  record Period, from : Time? = nil, to : Time? = nil do
    def self.parse(query : URI::Params) : Period
      from = date_param(query, "von")
      to = date_param(query, "bis")
      if from && to && to < from
        raise Domain::ValidationError.new("„Bis“ liegt vor „Von“.")
      end
      new(from, to)
    end

    # Only an empty value means unset; blanks are an invalid date.
    private def self.date_param(query : URI::Params, name : String) : Time?
      value = query[name]? || ""
      Domain.parse_date(value) unless value.empty?
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

  record Download, name : String, content_type : String, body : String

  class Service
    def initialize(@d : Web::Deps)
    end

    def expenses_csv(period : Period) : Download
      body = String.build { |io| Export.write_expenses_csv(io, @d.store.list_participants(true), expenses(period)) }
      Download.new("zipfelkasse-ausgaben-#{period.suffix(@d.today)}.csv", "text/csv; charset=utf-8", body)
    end

    def expenses_json(period : Period) : Download
      body = String.build do |io|
        Export.write_expenses_json(io, @d.store.group_name, @d.now, period, @d.store.list_participants(true), expenses(period))
      end
      Download.new("zipfelkasse-ausgaben-#{period.suffix(@d.today)}.json", "application/json; charset=utf-8", body)
    end

    def ynab_ofx(participant : Store::Participant, period : Period) : Download
      body = String.build do |io|
        Export.write_ofx(io, postings(participant.id, period), "ZIPFELKASSE-#{participant.id}", period.from, period.to,
          @d.now.in(@d.config.location))
      end
      Download.new("zipfelkasse-ynab-#{period.suffix(@d.today)}.ofx", "application/x-ofx", body)
    end

    def ynab_csv(participant : Store::Participant, period : Period) : Download
      body = String.build { |io| Export.write_ynab_csv(io, postings(participant.id, period)) }
      Download.new("zipfelkasse-ynab-#{period.suffix(@d.today)}.csv", "text/csv; charset=utf-8", body)
    end

    # Non-deleted expenses in the range, oldest first.
    private def expenses(period : Period, participant_id : Int64? = nil) : Array(Store::Expense)
      @d.store.list_expenses(Store::ExpenseFilter.new(from: period.from, to: period.to, participant_id: participant_id)).reverse!
    end

    # The participant's postings in the range, selected like the YNAB sync
    # does (start date, entered later, already transferred, nothing in the
    # future).
    private def postings(participant_id : Int64, period : Period) : Array(YNAB::Posting)
      selection = YNAB::Selection.for_participant(@d.store, participant_id, YNAB.today(@d.now, @d.config.location))
      selection.postings(expenses(period, participant_id), participant_id)
    end
  end

  module Views
    record Index, from : String, to : String do
      Web.view "export/index.ecr"
    end
  end

  class Handlers < Web::Controller
    def initialize(deps : Web::Deps, @service : Service)
      super(deps)
    end

    def register : Nil
      get("/export") { |env| with_period(env) { |period| show(env, 200, period) } }
      get("/export/ausgaben.csv") { |env| with_period(env) { |period| download(env, @service.expenses_csv(period)) } }
      get("/export/ausgaben.json") { |env| with_period(env) { |period| download(env, @service.expenses_json(period)) } }
      get("/export/ynab.ofx") { |env| with_period(env) { |period| download(env, @service.ynab_ofx(env.me, period)) } }
      get("/export/ynab.csv") { |env| with_period(env) { |period| download(env, @service.ynab_csv(env.me, period)) } }
    end

    # Every route answers an invalid range with the page (422, empty fields).
    private def with_period(env : HTTP::Server::Context, & : Period -> String) : String
      yield Period.parse(env.params.query)
    rescue ex : Domain::ValidationError
      show(env, 422, Period.new, ex.msg)
    end

    private def show(env : HTTP::Server::Context, status : Int32, period : Period, error : String? = nil) : String
      view = Views::Index.new(period.from.try { |t| Store.format_date(t) } || "", period.to.try { |t| Store.format_date(t) } || "")
      page(env, view, "Export", Web::Nav::Settings, status, error)
    end

    private def download(env : HTTP::Server::Context, file : Download) : String
      response = env.response
      response.content_type = file.content_type
      response.headers["Content-Disposition"] = %(attachment; filename="#{file.name}")
      response.headers["Cache-Control"] = "no-store"
      response.content_length = file.body.bytesize
      file.body
    end
  end
end
