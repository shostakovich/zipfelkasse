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
      return api_error(env, 400, "Ungültige Währung „#{raw}“.") unless currency == "EUR" || Domain.valid_currency_code?(currency)
      date = @d.today
      unless (value = env.query("datum")).empty?
        begin
          date = Domain.parse_date(value)
        rescue ex : Domain::ValidationError
          return api_error(env, 400, ex.msg)
        end
      end
      rate = begin
        @service.rate(currency, date)
      rescue ex : Domain::ValidationError
        return api_error(env, 422, ex.msg)
      rescue ex : FetchError
        return api_error(env, 502, ex.message || "")
      rescue ex
        Log.error(exception: ex, &.emit("rate", currency: currency))
        return api_error(env, 500, "Der Kurs konnte nicht ermittelt werden.")
      end
      env.response.content_type = "application/json; charset=utf-8"
      RateResponse.new(rate.currency, Store.format_date(rate.date), rate.rate, rate.source).to_json
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
      form = ManualForm.new(env.form("waehrung").strip.upcase, env.form("datum").strip, env.form("kurs").strip)
      begin
        @d.store.set_manual_fx_rate(env.me.id, form.currency, Domain.parse_date(form.date), Domain.parse_rate(form.rate))
      rescue ex : Domain::ValidationError
        return show(env, form, 422, ex.msg)
      end
      redirect(env, "/einstellungen/kurse", "Kurs für #{form.currency} gespeichert.")
    end

    private def delete_manual(env : HTTP::Server::Context) : String
      currency = env.form("waehrung").strip.upcase
      gone = "Diesen manuellen Kurs gibt es nicht (mehr)."
      date = begin
        Domain.parse_date(env.form("datum"))
      rescue Domain::ValidationError
        raise Web::HTTPError.new(env, 404, gone)
      end
      or_404(env, gone) { @d.store.delete_manual_fx_rate(env.me.id, currency, date) }
      redirect(env, "/einstellungen/kurse", "Manueller Kurs für #{currency} gelöscht.")
    end

    private def refresh_now(env : HTTP::Server::Context) : String
      latest = begin
        @service.refresh
      rescue ex : FetchError
        return show(env, ManualForm.new, 502, ex.message)
      end
      redirect(env, "/einstellungen/kurse", "EZB-Kurse aktualisiert (Stand #{Domain.format_date(latest)}).")
    end
  end
end
