module Zipfelkasse
  class Store
    ACTION_RECURRING_CREATED = "recurring_created"
    ACTION_RECURRING_DELETED = "recurring_deleted"

    # A rule for a recurring expense. The template's date and recurring_id
    # are meaningless.
    struct Recurring
      getter id : Int64
      getter template : ExpenseInput
      getter frequency : Domain::Frequency
      getter start_date : Time # anchor from which all occurrences are computed
      getter next_date : Time  # next occurrence not yet created
      getter? active : Bool
      getter created_by : Int64 # 0 = unknown
      getter created_at : Time?
      getter updated_at : Time?

      def initialize(@id, @template, @frequency, @start_date, @next_date, @active, @created_by,
                     @created_at = nil, @updated_at = nil)
      end
    end

    RECURRING_COLS = "id, template_json, frequency, start_date, next_date, active, created_by, created_at, updated_at"

    protected def self.read_recurring(rs : DB::ResultSet) : Recurring
      id, tmpl, freq = rs.read(Int64), rs.read(String), rs.read(String)
      start, next_date, active = rs.read(String), rs.read(String), rs.read(Bool)
      created_by, created, updated = rs.read(Int64?), rs.read(String?), rs.read(String?)
      template = begin
        ExpenseInput.from_json(tmpl)
      rescue ex
        raise Exception.new("recurring #{id}: template: #{ex.message}")
      end
      Recurring.new(id, template, Domain::Frequency.new(freq),
        recurring_date(id, "start_date", start), recurring_date(id, "next_date", next_date),
        active, created_by || 0_i64, parse_time(created), parse_time(updated))
    end

    private def self.recurring_date(id : Int64, column : String, value : String) : Time
      parse_date(value)
    rescue ex
      raise Exception.new("recurring #{id}: #{column} #{value.inspect}: #{ex.message}")
    end

    private def query_recurring(q : String, *args) : Array(Recurring)
      out = [] of Recurring
      @db.query(q, *args) { |rs| rs.each { out << Store.read_recurring(rs) } }
      out
    end

    protected def self.template_of(e : Expense) : ExpenseInput
      t = e.input
      t.date = nil
      t.recurring_id = 0_i64
      t
    end

    # The expense becomes the template and first instance: the anchor is its
    # date, it gets the recurring_id, and the next occurrence is the first one
    # after the anchor.
    def create_recurring_from_expense(actor_id : Int64, expense_id : Int64, freq : Domain::Frequency) : Int64
      raise Domain::ValidationError.new("Bitte eine Häufigkeit wählen.") unless freq.valid?
      transaction do |tx|
        e = Store.get_expense(tx, expense_id)
        raise NotFound.new if e.deleted?
        if e.recurring_id != 0
          raise Domain::ValidationError.new("Diese Ausgabe gehört schon zu einer wiederkehrenden Ausgabe.")
        end
        now = now_string
        next_date = Domain.next_date(freq, e.date, e.date)
        id = tx.exec("INSERT INTO recurring (template_json, frequency, start_date, next_date, active, created_by, created_at, updated_at) " \
                     "VALUES (?, ?, ?, ?, 1, ?, ?, ?)",
          Store.template_of(e).to_json, freq.value, Store.format_date(e.date), Store.format_date(next_date),
          Store.null_int(actor_id), now, now).last_insert_id
        tx.exec("UPDATE expenses SET recurring_id = ? WHERE id = ?", id, expense_id)
        insert_activity(tx, actor_id, ACTION_RECURRING_CREATED, expense_id, ActivityDetails.new(
          title: e.title, amount_cents: e.amount_cents, text: "„#{e.title}“ wiederholt sich jetzt #{freq.adverb}."))
        id
      end
    end

    # Raises NotFound.
    def get_recurring(id : Int64) : Recurring
      Store.get_recurring(@db, id)
    end

    def self.get_recurring(db : DB::QueryMethods, id : Int64) : Recurring
      db.query("SELECT #{RECURRING_COLS} FROM recurring WHERE id = ?", id) do |rs|
        rs.each { return read_recurring(rs) }
      end
      raise NotFound.new
    end

    # Active rules first, then by next occurrence.
    def list_recurring : Array(Recurring)
      query_recurring("SELECT #{RECURRING_COLS} FROM recurring ORDER BY active DESC, next_date, id")
    end

    # Active rules with next_date <= today.
    def due_recurring(today : Time) : Array(Recurring)
      query_recurring("SELECT #{RECURRING_COLS} FROM recurring WHERE active = 1 AND next_date <= ? ORDER BY next_date, id",
        Store.format_date(today))
    end

    # The dates in [from, to] with a non-deleted expense like input: same
    # title, payer and amount (for a foreign currency the original amount and
    # currency, since the euro amount depends on the rate). Recurrences skip
    # such occurrences, e.g. after a rule was deleted (its expenses lose their
    # recurring_id) and created again, or when the expense was entered by hand.
    def expense_dates_like(input : ExpenseInput, from : Time, to : Time) : Set(Time)
      q = "SELECT DISTINCT date FROM expenses " \
          "WHERE deleted_at IS NULL AND date BETWEEN ? AND ? AND title = ? AND paid_by = ? AND original_currency = ?"
      args = [Store.format_date(from), Store.format_date(to), Store.normalize_name(input.title), input.paid_by] of DB::Any
      if Domain.eur?(input.original_currency)
        q += " AND amount_cents = ?"
        args << "EUR" << input.amount_cents
      else
        q += " AND original_amount_minor = ?"
        args << input.original_currency.strip.upcase << input.original_amount_minor
      end
      @db.query_all(q, args: args, as: String).map { |d| Store.parse_date(d) }.to_set
    end

    # Optimistic locking: a catch-up works on a snapshot of the rule, so it
    # only advances next_date if the rule is still active and still at from;
    # otherwise raises RecurringChanged.
    def set_recurring_next_date(id : Int64, from : Time, next_date : Time) : Nil
      transaction do |tx|
        result = tx.exec("UPDATE recurring SET next_date = ?, updated_at = ? WHERE id = ? AND active = 1 AND next_date = ?",
          Store.format_date(next_date), now_string, id, Store.format_date(from))
        raise RecurringChanged.new if result.rows_affected == 0
      end
    end

    protected def self.rule_label(r : Recurring) : String
      "Wiederholung „#{r.template.title}“ (#{r.frequency.label.downcase})"
    end

    # On resume, occurrences from the pause are not caught up: next_date
    # becomes the first occurrence from today on (unless it is later anyway).
    def set_recurring_active(actor_id : Int64, id : Int64, active : Bool, today : Time) : Nil
      transaction do |tx|
        r = Store.get_recurring(tx, id)
        next_date, verb = r.next_date, "pausiert"
        if active
          verb = "fortgesetzt"
          if !r.active? && next_date < today
            next_date = Domain.next_date(r.frequency, r.start_date, today.shift(days: -1))
          end
        end
        tx.exec("UPDATE recurring SET active = ?, next_date = ?, updated_at = ? WHERE id = ?",
          active, Store.format_date(next_date), now_string, id)
        log_settings(tx, actor_id, "#{Store.rule_label(r)} #{verb}")
      end
    end

    # Adopts the most recent non-deleted instance as the new template, e.g.
    # after its amount was changed. Raises NotFound or NoInstance.
    def update_recurring_template_from_latest(actor_id : Int64, id : Int64) : Nil
      transaction do |tx|
        r = Store.get_recurring(tx, id)
        latest = Store.query_expenses(tx,
          EXPENSE_SELECT + " WHERE e.recurring_id = ? AND e.deleted_at IS NULL ORDER BY e.date DESC, e.id DESC LIMIT 1",
          [id] of DB::Any).first? || raise NoInstance.new
        tx.exec("UPDATE recurring SET template_json = ?, updated_at = ? WHERE id = ?",
          Store.template_of(latest).to_json, now_string, id)
        log_settings(tx, actor_id, "#{Store.rule_label(r)}: Vorlage aus der letzten Ausgabe übernommen")
      end
    end

    # Expenses already created are kept; ON DELETE SET NULL clears their
    # recurring_id.
    def delete_recurring(actor_id : Int64, id : Int64) : Nil
      transaction do |tx|
        r = Store.get_recurring(tx, id)
        tx.exec("DELETE FROM recurring WHERE id = ?", id)
        insert_activity(tx, actor_id, ACTION_RECURRING_DELETED, 0_i64, ActivityDetails.new(
          title: r.template.title, amount_cents: r.template.amount_cents,
          text: "Wiederholung von „#{r.template.title}“ beendet."))
      end
    end
  end
end
