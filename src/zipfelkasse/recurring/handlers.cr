module Zipfelkasse::Recurring
  LIST_PATH = "/einstellungen/wiederkehrend"

  # A frequency to choose in the form, with what it would do for the expense.
  record FreqOption, preview : Preview, checked : Bool do
    delegate next_date, to: preview

    def value : Domain::Frequency
      preview.frequency
    end

    def label : String
      Web.frequency_label(value)
    end

    # What happens to the missed occurrences, e.g. "3 verpasste Termine werden
    # sofort eingetragen; 1 bereits als Ausgabe vorhandener Termin wird
    # übersprungen"; empty if there are none.
    def note : String
      missed, existing = preview.missed, preview.existing
      capped = missed > MAX_MISSED_COUNT
      when_created = "sofort eingetragen"
      if missed > MAX_INSTANCES_PER_RUN
        when_created = "eingetragen – die ersten #{MAX_INSTANCES_PER_RUN} Termine sofort, der Rest in den nächsten Stunden"
      end
      parts = [] of String
      created = missed - existing
      if capped
        parts << "mehr als #{MAX_MISSED_COUNT} verpasste Termine werden #{when_created}"
      elsif created == 1
        parts << "1 verpasster Termin wird #{when_created}"
      elsif created > 1
        parts << "#{created} verpasste Termine werden #{when_created}"
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

  module Views
    record RuleRow, rule : Store::Recurring, paid_by_name : String?

    record Index, rules : Array(RuleRow) do
      Web.view "recurring/index.ecr"
    end

    # expense is nil without a chosen expense; options are empty until a
    # frequency can be chosen.
    record New, expense : Store::Expense?, options : Array(FreqOption) do
      Web.view "recurring/new.ecr"

      def existing : Int64?
        expense.try(&.recurring_id)
      end
    end
  end

  class Handlers < Web::Controller
    def initialize(deps : Web::Deps, @service : Service)
      super(deps)
    end

    def register : Nil
      get(LIST_PATH) { |env| list(env) }
      get("#{LIST_PATH}/neu") { |env| new_form(env) }
      post("#{LIST_PATH}/neu") { |env| create(env) }
      post("#{LIST_PATH}/:id/pausieren") { |env| set_active(env, false) }
      post("#{LIST_PATH}/:id/fortsetzen") { |env| set_active(env, true) }
      post("#{LIST_PATH}/:id/vorlage") { |env| refresh_template(env) }
      post("#{LIST_PATH}/:id/loeschen") { |env| delete(env) }
    end

    private def list(env : HTTP::Server::Context) : String
      names = @d.store.list_participants(true).to_h { |p| {p.id, p.name} }
      rows = @d.store.list_recurring.map { |rule| Views::RuleRow.new(rule, rule.template.paid_by.try { |id| names[id]? }) }
      page(env, Views::Index.new(rows), "Wiederkehrende Ausgaben", Web::Nav::Settings)
    end

    private def rule_id(env : HTTP::Server::Context) : Int64
      path_id(env) || raise Web::HTTPError.new(env, 404, "Wiederkehrende Ausgabe nicht gefunden.")
    end

    private def set_active(env : HTTP::Server::Context, active : Bool) : String
      id = rule_id(env)
      or_404(env, "Wiederkehrende Ausgabe nicht gefunden.") { @d.store.set_recurring_active(env.me.id, id, active, @d.today) }
      message = "Pausiert."
      if active
        message = "Fortgesetzt."
        created = materialize_logged(id)
        message += " #{count_text(created)} angelegt." if created > 0
      end
      redirect(env, LIST_PATH, message)
    end

    # Errors are only logged: the rule itself was changed.
    private def materialize_logged(id : Int64) : Int32
      @service.materialize_rule(id, @d.today)
    rescue ex : Error
      Log.error(exception: ex) { "recurring expenses" }
      ex.created
    rescue ex
      Log.error(exception: ex) { "recurring expenses" }
      0
    end

    private def refresh_template(env : HTTP::Server::Context) : String
      id = rule_id(env)
      message = begin
        or_404(env, "Wiederkehrende Ausgabe nicht gefunden.") { @d.store.update_recurring_template_from_latest(env.me.id, id) }
        "Vorlage aus der letzten Ausgabe übernommen."
      rescue Store::NoInstance
        "Es gibt keine Ausgabe dieser Wiederholung mehr, aus der die Vorlage übernommen werden könnte."
      end
      redirect(env, LIST_PATH, message)
    end

    private def delete(env : HTTP::Server::Context) : String
      id = rule_id(env)
      or_404(env, "Wiederkehrende Ausgabe nicht gefunden.") { @d.store.delete_recurring(env.me.id, id) }
      redirect(env, LIST_PATH, "Wiederholung gelöscht. Bereits angelegte Ausgaben bleiben erhalten.")
    end

    private def find_expense(env : HTTP::Server::Context, value : String) : Store::Expense
      id = Web.positive_id?(value)
      expense = or_404(env, "Ausgabe nicht gefunden.", id && @d.store.get_expense?(id))
      raise Web::HTTPError.new(env, 404, "Ausgabe nicht gefunden.") if expense.deleted?
      expense
    end

    private def new_form(env : HTTP::Server::Context) : String
      value = env.query("ausgabe")
      return show_form(env, nil) if value.empty?
      expense = find_expense(env, value)
      show_form(env, expense, @service.previews(expense), Domain::Frequency::Monthly)
    end

    private def create(env : HTTP::Server::Context) : String
      expense = find_expense(env, env.form("ausgabe"))
      frequency = Domain::Frequency.parse?(env.form("haeufigkeit"))
      id = begin
        @d.store.create_recurring_from_expense(env.me.id, expense.id, frequency || raise Domain::ValidationError.new("Bitte eine Häufigkeit wählen."))
      rescue ex : Domain::ValidationError
        return show_form(env, expense, @service.previews(expense), frequency, 422, ex.msg)
      rescue Store::NotFound
        raise Web::HTTPError.new(env, 404, "Ausgabe nicht gefunden.")
      end
      message = "„#{expense.title}“ wiederholt sich jetzt #{Web.frequency_adverb(frequency)}."
      created = materialize_logged(id)
      message += " #{count_text(created)} nachgetragen." if created > 0
      redirect(env, LIST_PATH, message)
    end

    private def show_form(env : HTTP::Server::Context, expense : Store::Expense?, previews = [] of Preview,
                          selected : Domain::Frequency? = nil, status = 200, error : String? = nil) : String
      options = previews.map { |preview| FreqOption.new(preview, preview.frequency == selected) }
      page(env, Views::New.new(expense, options), "Wiederkehrende Ausgabe anlegen", Web::Nav::Settings, status, error)
    end

    private def count_text(count : Int32) : String
      count == 1 ? "1 Ausgabe" : "#{count} Ausgaben"
    end
  end
end
