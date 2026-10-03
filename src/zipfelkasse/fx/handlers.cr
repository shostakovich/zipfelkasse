module Zipfelkasse::FX
  record RateRow,
    currency : String,
    date : Time,
    rate : String,      # German format, e.g. "1,1298"
    source : String,    # display label: "EZB", "manuell", …
    title : String = "", # used rates: title of the expense
    id : Int64 = 0_i64   # used rates: the expense

  record ManualForm, currency : String = "", date : String = "", rate : String = ""

  def self.source_label(source : String) : String
    case source
    when Domain::FX_SOURCE_ECB    then "EZB"
    when Domain::FX_SOURCE_MANUAL then "manuell"
    when Domain::FX_SOURCE_FIXED  then "fest"
    when ""                       then "–"
    else                               source
    end
  end

  def self.rows(rates : Array(Domain::FXRate)) : Array(RateRow)
    rates.map { |r| RateRow.new(r.currency, r.date, Domain.format_rate(r.rate), source_label(r.source)) }
  end

  class Service
    def register : Nil
      d = @d
      Web.route(d, "GET", "/api/kurs") { |r| api_rate(r) }
      Web.route(d, "GET", "/einstellungen/kurse") { |r| render_page(r, 200, ManualForm.new, "") }
      Web.route(d, "POST", "/einstellungen/kurse") { |r| save_manual(r) }
      Web.route(d, "POST", "/einstellungen/kurse/loeschen") { |r| delete_manual(r) }
      Web.route(d, "POST", "/einstellungen/kurse/aktualisieren") { |r| refresh_now(r) }
    end

    private def api_rate(r : Web::Request) : Nil
      raw = r.query("waehrung")
      cur = raw.strip.upcase
      return r.json_error(400, "Bitte eine Währung angeben.") if cur.empty?
      return r.json_error(400, "Ungültige Währung „#{raw}“.") unless cur == "EUR" || Domain.valid_currency_code?(cur)
      date = today
      unless (v = r.query("datum")).empty?
        begin
          date = Domain.parse_date(v)
        rescue ex : Domain::ValidationError
          return r.json_error(400, ex.msg)
        end
      end
      fx = begin
        rate(cur, date)
      rescue ex : Domain::ValidationError
        return r.json_error(422, ex.msg)
      rescue ex : FetchError
        return r.json_error(502, ex.message || "")
      rescue ex
        @d.log.error("rate", currency: cur, err: ex)
        return r.json_error(500, "Der Kurs konnte nicht ermittelt werden.")
      end
      r.json(200) do |j|
        j.object do
          j.field "currency", fx.currency
          j.field "date", Store.format_date(fx.date)
          # Shortest digits without exponent or ".0": 1 stays 1, not 1.0.
          j.field("rate") { j.raw Domain.format_rate(fx.rate).sub(',', '.') }
          j.field "source", fx.source
        end
      end
    end

    private def render_page(r : Web::Request, status : Int32, form : ManualForm, error : String) : Nil
      form = form.copy_with(date: Store.format_date(today)) if form.date.empty?
      store = @d.store
      manual = FX.rows(store.list_manual_fx_rates)
      latest = FX.rows(store.latest_ecb_rates)
      stats = store.ecb_cache_stats
      used = store.recent_used_fx_rates(10).map do |u|
        RateRow.new(u.currency, u.date, Domain.format_rate(u.rate), FX.source_label(u.source), u.title, u.expense_id)
      end
      currencies = store.list_fx_currencies
      r.page(status, Web::Page.new(title: "Wechselkurse", nav: Web::NAV_SETTINGS, error: error)) do |__io__|
        Web.template __io__, "fx/kurse.ecr"
      end
    end

    private def save_manual(r : Web::Request) : Nil
      form = ManualForm.new(r.form_value("waehrung").strip.upcase, r.form_value("datum").strip, r.form_value("kurs").strip)
      begin
        date = Domain.parse_date(form.date)
        rate = Domain.parse_rate(form.rate)
        @d.store.set_manual_fx_rate(r.me.id, form.currency, date, rate)
      rescue ex : Domain::ValidationError
        return render_page(r, 422, form, ex.msg)
      end
      r.set_flash("Kurs für #{form.currency} gespeichert.")
      r.redirect("/einstellungen/kurse")
    end

    private def delete_manual(r : Web::Request) : Nil
      cur = r.form_value("waehrung").strip.upcase
      begin
        @d.store.delete_manual_fx_rate(r.me.id, cur, Domain.parse_date(r.form_value("datum")))
      rescue Store::NotFound | Domain::ValidationError
        return render_page(r, 404, ManualForm.new, "Diesen manuellen Kurs gibt es nicht (mehr).")
      end
      r.set_flash("Manueller Kurs für #{cur} gelöscht.")
      r.redirect("/einstellungen/kurse")
    end

    private def refresh_now(r : Web::Request) : Nil
      latest = begin
        refresh
      rescue ex : FetchError
        return render_page(r, 502, ManualForm.new, ex.message || "")
      end
      r.set_flash("EZB-Kurse aktualisiert (Stand #{Domain.format_date(latest)}).")
      r.redirect("/einstellungen/kurse")
    end
  end
end
