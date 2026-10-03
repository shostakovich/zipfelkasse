module Zipfelkasse::Recurring
  LIST_PATH = "/einstellungen/wiederkehrend"

  # The preview counts missed occurrences up to this, beyond it says
  # "mehr als 1000".
  MAX_MISSED_COUNT = 1000

  struct FreqOption
    getter value : Domain::Frequency
    getter next_date : Time? # first occurrence after the template
    getter missed : Int32    # occurrences up to today (counted up to MAX_MISSED_COUNT + 1)
    getter existing : Int32  # of these, skipped since an equal expense exists
    getter? checked : Bool

    def initialize(*, @value = Domain::FREQ_MONTHLY, @next_date = nil, @missed = 0, @existing = 0, @checked = false)
    end

    def label : String
      value.label
    end

    # What happens to the missed occurrences, e.g. "3 verpasste Termine werden
    # sofort eingetragen; 1 bereits als Ausgabe vorhandener Termin wird
    # übersprungen"; "" if there are none.
    def note : String
      capped = missed > MAX_MISSED_COUNT
      w = "sofort eingetragen"
      if missed > MAX_INSTANCES_PER_RUN
        w = "eingetragen – die ersten #{MAX_INSTANCES_PER_RUN} Termine sofort, der Rest in den nächsten Stunden"
      end
      parts = [] of String
      n = missed - existing
      if capped
        parts << "mehr als #{MAX_MISSED_COUNT} verpasste Termine werden #{w}"
      elsif n == 1
        parts << "1 verpasster Termin wird #{w}"
      elsif n > 1
        parts << "#{n} verpasste Termine werden #{w}"
      end
      at_least = capped ? "mindestens " : ""
      if existing == 1
        parts << "#{at_least}1 bereits als Ausgabe vorhandener Termin wird übersprungen"
      elsif existing > 1
        parts << "#{at_least}#{existing} bereits als Ausgabe vorhandene Termine werden übersprungen"
      end
      parts.join("; ")
    end
  end

  class Service
    def register : Nil
      Web.route(@d, "GET", LIST_PATH) { |r| list(r) }
      Web.route(@d, "GET", "#{LIST_PATH}/neu") { |r| new_page(r) }
      Web.route(@d, "POST", "#{LIST_PATH}/neu") { |r| create(r) }
      Web.route(@d, "POST", "#{LIST_PATH}/:id/pausieren") { |r| set_active(r, false) }
      Web.route(@d, "POST", "#{LIST_PATH}/:id/fortsetzen") { |r| set_active(r, true) }
      Web.route(@d, "POST", "#{LIST_PATH}/:id/vorlage") { |r| refresh_template(r) }
      Web.route(@d, "POST", "#{LIST_PATH}/:id/loeschen") { |r| delete(r) }
    end

    private def rule_not_found : Web::HTTPError
      Web::HTTPError.not_found("Wiederkehrende Ausgabe nicht gefunden.")
    end

    private def list(r : Web::Request) : Nil
      names = @d.store.list_participants(true).to_h { |p| {p.id, p.name} }
      rules = @d.store.list_recurring.map { |rule| {rule, names[rule.template.paid_by]? || ""} }
      r.page(200, Web::Page.new(title: "Wiederkehrende Ausgaben", nav: Web::NAV_SETTINGS)) do |__io__|
        Web.template __io__, "recurring/wiederkehrend.ecr"
      end
    end

    private def path_rule_id(r : Web::Request) : Int64
      id = r.path_id
      raise rule_not_found if id == 0
      id
    end

    private def set_active(r : Web::Request, active : Bool) : Nil
      id = path_rule_id(r)
      begin
        @d.store.set_recurring_active(r.me.id, id, active, today)
      rescue Store::NotFound
        raise rule_not_found
      end
      msg = "Pausiert."
      if active
        msg = "Fortgesetzt."
        n = materialize_logged(id)
        msg += " #{count_text(n)} angelegt." if n > 0
      end
      r.set_flash(msg)
      r.redirect(LIST_PATH)
    end

    # Errors are only logged: the rule itself was changed.
    private def materialize_logged(id : Int64) : Int32
      materialize_rule(id, today)
    rescue ex : Error
      log.error("recurring expenses", err: ex)
      ex.created
    rescue ex
      log.error("recurring expenses", err: ex)
      0
    end

    private def refresh_template(r : Web::Request) : Nil
      id = path_rule_id(r)
      begin
        @d.store.update_recurring_template_from_latest(r.me.id, id)
        r.set_flash("Vorlage aus der letzten Ausgabe übernommen.")
      rescue Store::NotFound
        raise rule_not_found
      rescue Store::NoInstance
        r.set_flash("Es gibt keine Ausgabe dieser Wiederholung mehr, aus der die Vorlage übernommen werden könnte.")
      end
      r.redirect(LIST_PATH)
    end

    private def delete(r : Web::Request) : Nil
      id = path_rule_id(r)
      begin
        @d.store.delete_recurring(r.me.id, id)
      rescue Store::NotFound
        raise rule_not_found
      end
      r.set_flash("Wiederholung gelöscht. Bereits angelegte Ausgaben bleiben erhalten.")
      r.redirect(LIST_PATH)
    end

    # The preview of each frequency: next occurrence and how many missed
    # occurrences would be created or skipped.
    def options(e : Store::Expense, selected : Domain::Frequency) : Array(FreqOption)
      today = self.today
      existing = Set(Time).new
      if e.date < today
        existing = @d.store.expense_dates_like(e.input, e.date.shift(days: 1), today)
      end
      Domain::FREQUENCIES.map do |f|
        first = Domain.next_date(f, e.date, e.date)
        missed = skipped = 0
        d = first
        while d <= today && missed <= MAX_MISSED_COUNT
          missed += 1
          skipped += 1 if existing.includes?(d)
          d = Domain.next_date(f, e.date, d)
        end
        FreqOption.new(value: f, next_date: first, missed: missed, existing: skipped, checked: f == selected)
      end
    end

    private def render_new(r : Web::Request, status : Int32, expense : Store::Expense?,
                           options = [] of FreqOption, error = "") : Nil
      existing = expense.try(&.recurring_id) || 0_i64
      r.page(status, Web::Page.new(title: "Wiederkehrende Ausgabe anlegen", nav: Web::NAV_SETTINGS, error: error)) do |__io__|
        Web.template __io__, "recurring/wiederkehrend_neu.ecr"
      end
    end

    # The expense from the "ausgabe" parameter (query or body).
    private def load_expense(r : Web::Request) : Store::Expense
      not_found = Web::HTTPError.not_found("Ausgabe nicht gefunden.")
      id = Web.form_id(r.form_value("ausgabe"), trim: false)
      raise not_found if id == 0
      e = begin
        @d.store.get_expense(id)
      rescue Store::NotFound
        raise not_found
      end
      raise not_found if e.deleted?
      e
    end

    private def new_page(r : Web::Request) : Nil
      return render_new(r, 200, nil) if r.form_value("ausgabe").empty?
      e = load_expense(r)
      render_new(r, 200, e, options(e, Domain::FREQ_MONTHLY))
    end

    private def create(r : Web::Request) : Nil
      e = load_expense(r)
      freq = Domain::Frequency.new(r.form_value("haeufigkeit"))
      id = begin
        @d.store.create_recurring_from_expense(r.me.id, e.id, freq)
      rescue ex : Domain::ValidationError
        return render_new(r, 422, e, options(e, freq), ex.msg)
      rescue Store::NotFound
        raise Web::HTTPError.not_found("Ausgabe nicht gefunden.")
      end
      msg = "„#{e.title}“ wiederholt sich jetzt #{freq.adverb}."
      n = materialize_logged(id)
      msg += " #{count_text(n)} nachgetragen." if n > 0
      r.set_flash(msg)
      r.redirect(LIST_PATH)
    end

    private def count_text(n : Int32) : String
      n == 1 ? "1 Ausgabe" : "#{n} Ausgaben"
    end
  end
end
