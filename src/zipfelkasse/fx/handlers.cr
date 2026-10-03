module Zipfelkasse::FX
  # rate is in German format, e.g. "1,1298"; title and expense_id only for
  # used rates.
  record RateRow, currency : String, date : Time, rate : String, source : String, title : String? = nil,
    expense_id : Int64? = nil

  record ManualForm, currency : String = "", date : String = "", rate : String = ""

  record RateResponse, currency : String, date : String, rate : Float64, source : Domain::FXSource do
    include JSON::Serializable
  end

  def self.source_label(source : Domain::FXSource) : String
    case source
    in .ecb?    then "EZB"
    in .manual? then "manuell"
    in .fixed?  then "fest"
    end
  end

  def self.rows(rates : Array(Domain::FXRate)) : Array(RateRow)
    rates.map { |r| RateRow.new(r.currency, r.date, Domain.format_rate(r.rate), source_label(r.source)) }
  end

  module Views
    record Rates, form : ManualForm, manual : Array(RateRow), latest : Array(RateRow), stats : Store::FXCacheStats,
      used : Array(RateRow), currencies : Array(String) do
      Web.view "fx/rates.ecr"
    end
  end

  class Handlers < Web::Controller
    def initialize(deps : Web::Deps, @service : Service)
      super(deps)
    end

    def register : Nil
      get("/api/kurs") { |env| api_rate(env) }
      get("/einstellungen/kurse") { |env| show(env, ManualForm.new) }
      post("/einstellungen/kurse") { |env| save_manual(env) }
      post("/einstellungen/kurse/loeschen") { |env| delete_manual(env) }
      post("/einstellungen/kurse/aktualisieren") { |env| refresh_now(env) }
    end

    private def api_rate(env : HTTP::Server::Context) : String
      raw = env.query("waehrung")
      currency = raw.strip.upcase
      return api_error(env, 400, "Bitte eine Währung angeben.") if currency.empty?
      return api_error(env, 400, "Ungültige Währung „#{raw}“.") unless Domain.valid_currency_code?(currency)
      date = begin
        env.query("datum").empty? ? @d.today : Domain.parse_date(env.query("datum"))
      rescue ex : Domain::ValidationError
        return api_error(env, 400, ex.msg)
      end
      rate = @service.rate(currency, date)
      env.response.content_type = "application/json; charset=utf-8"
      RateResponse.new(rate.currency, Store.format_date(rate.date), rate.rate, rate.source).to_json
    rescue ex : Domain::ValidationError
      api_error(env, 422, ex.msg)
    rescue ex : FetchError
      api_error(env, 502, ex.message || "")
    end

    private def show(env : HTTP::Server::Context, form : ManualForm, status = 200, error : String? = nil) : String
      form = form.copy_with(date: Store.format_date(@d.today)) if form.date.empty?
      store = @d.store
      used = store.recent_used_fx_rates(10).map do |u|
        RateRow.new(u.currency, u.date, Domain.format_rate(u.rate), FX.source_label(u.source), u.title, u.expense_id)
      end
      view = Views::Rates.new(form, FX.rows(store.list_manual_fx_rates), FX.rows(store.latest_ecb_rates),
        store.ecb_cache_stats, used, store.list_fx_currencies)
      page(env, view, "Wechselkurse", Web::Nav::Settings, status, error)
    end

    private def save_manual(env : HTTP::Server::Context) : String
      form = manual_form(env)
      @d.store.set_manual_fx_rate(env.me.id, form.currency, Domain.parse_date(form.date), Domain.parse_rate(form.rate))
      redirect(env, "/einstellungen/kurse", "Kurs für #{form.currency} gespeichert.")
    rescue ex : Domain::ValidationError
      show(env, manual_form(env), 422, ex.msg)
    end

    private def manual_form(env : HTTP::Server::Context) : ManualForm
      ManualForm.new(env.form("waehrung").strip.upcase, env.form("datum").strip, env.form("kurs").strip)
    end

    private def delete_manual(env : HTTP::Server::Context) : String
      currency = env.form("waehrung").strip.upcase
      or_404(env, "Diesen manuellen Kurs gibt es nicht (mehr).") do
        date = Domain.parse_date(env.form("datum")) rescue raise Store::NotFound.new
        @d.store.delete_manual_fx_rate(env.me.id, currency, date)
      end
      redirect(env, "/einstellungen/kurse", "Manueller Kurs für #{currency} gelöscht.")
    end

    private def refresh_now(env : HTTP::Server::Context) : String
      redirect(env, "/einstellungen/kurse", "EZB-Kurse aktualisiert (Stand #{Domain.format_date(@service.refresh)}).")
    rescue ex : FetchError
      show(env, ManualForm.new, 502, ex.message)
    end
  end
end
