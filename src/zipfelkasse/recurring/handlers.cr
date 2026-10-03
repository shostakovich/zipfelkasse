module Zipfelkasse::Recurring
  LIST_PATH = "/einstellungen/wiederkehrend"
  NOT_FOUND = "Wiederkehrende Ausgabe nicht gefunden."

  record FreqOption, preview : Preview, checked : Bool do
    delegate next_date, to: preview

    def value : Domain::Frequency
      preview.frequency
    end

    def label : String
      Web.frequency_label(value)
    end

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
      or_404(env, NOT_FOUND) { path_id(env) }
    end

    private def set_active(env : HTTP::Server::Context, active : Bool) : String
      id = rule_id(env)
      or_404(env, NOT_FOUND) { @d.store.set_recurring_active(env.me.id, id, active, @d.today) }
      return redirect(env, LIST_PATH, "Pausiert.") unless active
      created = materialize_logged(id)
      redirect(env, LIST_PATH, created > 0 ? "Fortgesetzt. #{Web::Helpers.expense_count(created)} angelegt." : "Fortgesetzt.")
    end

    # Errors are only logged: the rule itself was changed.
    private def materialize_logged(id : Int64) : Int32
      @service.materialize_rule(id, @d.today)
    rescue ex
      Log.error(exception: ex) { "recurring expenses" }
      ex.is_a?(Error) ? ex.created : 0
    end

    private def refresh_template(env : HTTP::Server::Context) : String
      id = rule_id(env)
      or_404(env, NOT_FOUND) { @d.store.update_recurring_template_from_latest(env.me.id, id) }
      redirect(env, LIST_PATH, "Vorlage aus der letzten Ausgabe übernommen.")
    rescue Store::NoInstance
      redirect(env, LIST_PATH, "Es gibt keine Ausgabe dieser Wiederholung mehr, aus der die Vorlage übernommen werden könnte.")
    end

    private def delete(env : HTTP::Server::Context) : String
      id = rule_id(env)
      or_404(env, NOT_FOUND) { @d.store.delete_recurring(env.me.id, id) }
      redirect(env, LIST_PATH, "Wiederholung gelöscht. Bereits angelegte Ausgaben bleiben erhalten.")
    end

    private def find_expense(env : HTTP::Server::Context, value : String) : Store::Expense
      or_404(env, "Ausgabe nicht gefunden.") do
        expense = @d.store.get_expense(Web.positive_id?(value) || raise Store::NotFound.new)
        raise Store::NotFound.new if expense.deleted?
        expense
      end
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
        raise Domain::ValidationError.new("Bitte eine Häufigkeit wählen.") unless frequency
        or_404(env, "Ausgabe nicht gefunden.") { @d.store.create_recurring_from_expense(env.me.id, expense.id, frequency) }
      rescue ex : Domain::ValidationError
        return show_form(env, expense, @service.previews(expense), frequency, 422, ex.msg)
      end
      created = materialize_logged(id)
      message = "„#{expense.title}“ wiederholt sich jetzt #{Web.frequency_adverb(frequency)}."
      message += " #{Web::Helpers.expense_count(created)} nachgetragen." if created > 0
      redirect(env, LIST_PATH, message)
    end

    private def show_form(env : HTTP::Server::Context, expense : Store::Expense?, previews = [] of Preview,
                          selected : Domain::Frequency? = nil, status = 200, error : String? = nil) : String
      options = previews.map { |preview| FreqOption.new(preview, preview.frequency == selected) }
      page(env, Views::New.new(expense, options), "Wiederkehrende Ausgabe anlegen", Web::Nav::Settings, status, error)
    end
  end
end
