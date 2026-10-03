module Zipfelkasse
  class Store
    class RecurringExists < Exception; end

    # The rule was paused, deleted or advanced since it was read.
    class RecurringChanged < Exception; end

    class NoInstance < Exception; end

    record Recurring,
      id : Int64,
      template : ExpenseInput,
      frequency : Domain::Frequency,
      start_date : Time, # the anchor of all occurrences
      next_date : Time,
      active : Bool,
      created_by : Int64?,
      created_at : Time,
      updated_at : Time do
      include DB::Serializable

      @[DB::Field(key: "template_json", converter: Zipfelkasse::Store::JSONText(Zipfelkasse::Store::ExpenseInput))]
      @template : ExpenseInput
      @[DB::Field(converter: Zipfelkasse::Store::DateText)]
      @start_date : Time
      @[DB::Field(converter: Zipfelkasse::Store::DateText)]
      @next_date : Time
      @[DB::Field(converter: Zipfelkasse::Store::TimeText)]
      @created_at : Time
      @[DB::Field(converter: Zipfelkasse::Store::TimeText)]
      @updated_at : Time

      def active? : Bool
        active
      end
    end

    RECURRING_COLS = "id, template_json, frequency, start_date, next_date, active, created_by, created_at, updated_at"

    # The expense becomes the template and the first instance.
    def create_recurring_from_expense(actor_id : Int64?, expense_id : Int64, freq : Domain::Frequency) : Int64
      transaction do |tx|
        e = get_expense(expense_id, tx)
        raise NotFound.new if e.deleted?
        if e.recurring_id
          raise Domain::ValidationError.new("Diese Ausgabe gehört schon zu einer wiederkehrenden Ausgabe.")
        end
        now = now_string
        next_date = Domain.next_date(freq, e.date, e.date)
        id = tx.exec("INSERT INTO recurring (template_json, frequency, start_date, next_date, active, created_by, created_at, updated_at) " \
                     "VALUES (?, ?, ?, ?, 1, ?, ?, ?)",
          e.to_input.to_json, freq.key, Store.format_date(e.date), Store.format_date(next_date), actor_id, now, now).last_insert_id
        tx.exec("UPDATE expenses SET recurring_id = ? WHERE id = ?", id, expense_id)
        insert_activity(tx, actor_id, Action::RecurringCreated, expense_id, ActivityDetails.new(
          title: e.title, amount_cents: e.amount_cents, text: "„#{e.title}“ wiederholt sich jetzt #{adverb(freq)}."))
        id
      end
    end

    def get_recurring?(id : Int64, db : DB::QueryMethods = @db) : Recurring?
      db.query_one?("SELECT #{RECURRING_COLS} FROM recurring WHERE id = ?", id, as: Recurring)
    end

    def get_recurring(id : Int64, db : DB::QueryMethods = @db) : Recurring
      get_recurring?(id, db) || raise NotFound.new
    end

    def list_recurring : Array(Recurring)
      @db.query_all("SELECT #{RECURRING_COLS} FROM recurring ORDER BY active DESC, next_date, id", as: Recurring)
    end

    def due_recurring(today : Time) : Array(Recurring)
      @db.query_all("SELECT #{RECURRING_COLS} FROM recurring WHERE active = 1 AND next_date <= ? ORDER BY next_date, id",
        Store.format_date(today), as: Recurring)
    end

    # Same title, payer and amount (of a foreign currency the original one): a
    # recurrence skips these dates, e.g. after it was deleted and created again.
    def expense_dates_like(input : ExpenseInput, from : Time, to : Time) : Set(Time)
      currency, amount_column, amount =
        if Domain.eur?(input.original_currency)
          {"EUR", "amount_cents", input.amount_cents}
        else
          {input.original_currency.strip.upcase, "original_amount_minor", input.original_amount_minor}
        end
      @db.query_all("SELECT DISTINCT date FROM expenses WHERE deleted_at IS NULL AND date BETWEEN ? AND ? " \
                    "AND title = ? AND paid_by = ? AND original_currency = ? AND #{amount_column} = ?",
        Store.format_date(from), Store.format_date(to), Store.normalize_name(input.title), input.paid_by, currency, amount,
        as: String).map { |d| Store.parse_date(d) }.to_set
    end

    # Optimistic locking: a catch-up works on a snapshot of the rule.
    def set_recurring_next_date(id : Int64, from : Time, next_date : Time) : Nil
      transaction do |tx|
        result = tx.exec("UPDATE recurring SET next_date = ?, updated_at = ? WHERE id = ? AND active = 1 AND next_date = ?",
          Store.format_date(next_date), now_string, id, Store.format_date(from))
        raise RecurringChanged.new if result.rows_affected == 0
      end
    end

    private def rule_label(r : Recurring) : String
      "Wiederholung „#{r.template.title}“ (#{adverb(r.frequency)})"
    end

    # Persisted activity text: German, whatever the UI labels say later.
    private def adverb(freq : Domain::Frequency) : String
      case freq
      in .weekly?  then "wöchentlich"
      in .monthly? then "monatlich"
      in .yearly?  then "jährlich"
      end
    end

    # On resume, occurrences from the pause are not caught up.
    def set_recurring_active(actor_id : Int64?, id : Int64, active : Bool, today : Time) : Nil
      transaction do |tx|
        r = get_recurring(id, tx)
        next_date = r.next_date
        if active && !r.active? && next_date < today
          next_date = Domain.next_date(r.frequency, r.start_date, today.shift(days: -1))
        end
        tx.exec("UPDATE recurring SET active = ?, next_date = ?, updated_at = ? WHERE id = ?",
          active, Store.format_date(next_date), now_string, id)
        log_settings(tx, actor_id, "#{rule_label(r)} #{active ? "fortgesetzt" : "pausiert"}")
      end
    end

    def update_recurring_template_from_latest(actor_id : Int64?, id : Int64) : Nil
      transaction do |tx|
        r = get_recurring(id, tx)
        latest = tx.query_one?("#{EXPENSE_SELECT} WHERE e.recurring_id = ? AND e.deleted_at IS NULL " \
                               "ORDER BY e.date DESC, e.id DESC LIMIT 1", id, as: Expense) || raise NoInstance.new
        tx.exec("UPDATE recurring SET template_json = ?, updated_at = ? WHERE id = ?",
          latest.to_input.to_json, now_string, id)
        log_settings(tx, actor_id, "#{rule_label(r)}: Vorlage aus der letzten Ausgabe übernommen")
      end
    end

    def delete_recurring(actor_id : Int64?, id : Int64) : Nil
      transaction do |tx|
        r = get_recurring(id, tx)
        tx.exec("DELETE FROM recurring WHERE id = ?", id)
        insert_activity(tx, actor_id, Action::RecurringDeleted, nil, ActivityDetails.new(
          title: r.template.title, amount_cents: r.template.amount_cents,
          text: "Wiederholung von „#{r.template.title}“ beendet."))
      end
    end
  end
end
