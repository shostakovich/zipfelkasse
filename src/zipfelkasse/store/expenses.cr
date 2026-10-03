module Zipfelkasse
  class Store
    private EXPENSE_ORDER = {
      ""               => "e.date DESC, e.id DESC",
      SORT_DATE_DESC   => "e.date DESC, e.id DESC",
      SORT_DATE_ASC    => "e.date, e.id",
      SORT_AMOUNT_DESC => "e.amount_cents DESC, e.date DESC, e.id DESC",
      SORT_AMOUNT_ASC  => "e.amount_cents, e.date DESC, e.id DESC",
    }

    # The prefix query_expenses expects (column order matters).
    EXPENSE_SELECT = "SELECT e.id, e.title, e.date, e.category_id, e.paid_by, e.notes, e.is_reimbursement, " \
                     "e.split_mode, e.amount_cents, e.original_amount_minor, e.original_currency, e.fx_rate, e.fx_source, " \
                     "e.recurring_id, e.created_at, e.updated_at, e.deleted_at, coalesce(c.name, ''), p.name " \
                     "FROM expenses e " \
                     "LEFT JOIN categories c ON c.id = e.category_id " \
                     "JOIN participants p ON p.id = e.paid_by"

    # As maxlength in the expense form.
    MAX_NOTES_LEN = 2000

    # "Title or notes of e contain one of terms", compared folded (LIKE would
    # only ignore the case of ASCII letters). Empty without terms.
    protected def self.text_cond(terms : Enumerable(String)) : {String, Array(DB::Any)}
      ors = [] of String
      args = [] of DB::Any
      terms.each do |t|
        t = t.strip
        next if t.empty?
        t = fold(t)
        ors << "instr(#{FOLD_FUNC}(e.title), ?) > 0 OR instr(#{FOLD_FUNC}(e.notes), ?) > 0"
        args << t << t
      end
      return {"", args} if ors.empty?
      {"(" + ors.join(" OR ") + ")", args}
    end

    # Validates the input including the split. The cent shares are computed
    # by split_shares once the expense ID is known.
    protected def self.normalize_expense(input : ExpenseInput) : ExpenseInput
      input.title = normalize_name(input.title)
      input.notes = input.notes.strip
      date = input.date
      raise Domain::ValidationError.new("Bitte einen Titel angeben.") if input.title.empty?
      raise Domain::ValidationError.new("Der Titel ist zu lang (höchstens 200 Zeichen).") if input.title.size > 200
      # Browsers count a line break as one character for maxlength but send
      # it as CR LF.
      if input.notes.gsub("\r\n", "\n").size > MAX_NOTES_LEN
        raise Domain::ValidationError.new("Die Notiz ist zu lang (höchstens #{MAX_NOTES_LEN} Zeichen).")
      end
      raise Domain::ValidationError.new("Bitte ein Datum angeben.") if date.nil?
      raise Domain::ValidationError.new("Bitte angeben, wer bezahlt hat.") if input.paid_by <= 0
      input.date = Domain.date_of(date)
      if input.reimbursement?
        raise Domain::ValidationError.new("Eine Rückzahlung geht an genau eine Person.") if input.parts.size != 1
        if input.parts[0].participant_id == input.paid_by
          raise Domain::ValidationError.new("Bei einer Rückzahlung müssen Zahler und Empfänger verschieden sein.")
        end
        input.split_mode = Domain::SPLIT_EQUAL
      end
      if Domain.eur?(input.original_currency)
        input.original_currency = "EUR"
        input.original_amount_minor = input.amount_cents
        input.fx_rate = 1.0
        input.fx_source = ""
      else
        cur = input.original_currency.strip.upcase
        input.original_currency = cur
        raise Domain::ValidationError.new("Ungültige Währung „#{cur}“.") unless Domain.valid_currency_code?(cur)
        raise Domain::ValidationError.new("Bitte den Betrag in #{cur} angeben.") if input.original_amount_minor <= 0
        raise Domain::ValidationError.new("Bitte einen Wechselkurs für #{cur} angeben.") if input.fx_rate <= 0
        input.amount_cents = Domain.to_eur_cents(input.original_amount_minor, cur, input.fx_rate)
        if input.amount_cents <= 0
          raise Domain::ValidationError.new("Umgerechnet ergibt der Betrag 0 € – bitte Betrag und Kurs prüfen.")
        end
      end
      input.parts = split_shares(input, 0_i64).map { |sh| Domain::Part.new(sh.participant_id, sh.weight) }
      input
    end

    # The expense ID decides who gets the extra cent on ties.
    protected def self.split_shares(input : ExpenseInput, expense_id : Int64) : Array(Domain::Share)
      Domain.split_converted(input.split_mode, input.amount_cents, input.original_amount_minor,
        input.original_currency, input.parts, expense_id)
    end

    # Archived people and categories are accepted.
    protected def self.check_refs(tx : DB::Connection, input : ExpenseInput) : Nil
      ids = ([input.paid_by] + input.parts.map(&.participant_id)).uniq!.sort!
      n = tx.scalar("SELECT count(*) FROM participants WHERE id IN (#{placeholders(ids.size)})",
        args: ids.map(&.as(DB::Any))).as(Int64)
      raise Domain::ValidationError.new("Unbekannte Person in der Ausgabe.") if n != ids.size
      if input.category_id != 0
        n = tx.scalar("SELECT count(*) FROM categories WHERE id = ?", input.category_id).as(Int64)
        raise Domain::ValidationError.new("Unbekannte Kategorie.") if n != 1
      end
    end

    protected def self.insert_shares(tx : DB::Connection, expense_id : Int64, shares : Array(Domain::Share)) : Nil
      shares.each do |sh|
        tx.exec("INSERT INTO expense_shares (expense_id, participant_id, weight, amount_cents) VALUES (?, ?, ?, ?)",
          expense_id, sh.participant_id, sh.weight, sh.amount_cents)
      end
    end

    # actor_id 0 = system.
    def create_expense(actor_id : Int64, input : ExpenseInput) : Int64
      input = Store.normalize_expense(input)
      id = transaction do |tx|
        Store.check_refs(tx, input)
        if input.recurring_id != 0
          # Same transaction as the insert: a recurrence paused or deleted
          # meanwhile gets no instance (instead of a foreign key error).
          active = tx.query_one?("SELECT active FROM recurring WHERE id = ?", input.recurring_id, as: Int64)
          raise RecurringChanged.new if active.nil? || active == 0
        end
        now = now_string
        res = begin
          tx.exec("INSERT INTO expenses (title, date, category_id, paid_by, notes, is_reimbursement, split_mode, " \
                  "amount_cents, original_amount_minor, original_currency, fx_rate, fx_source, recurring_id, " \
                  "created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            input.title, Store.format_date(input.date.not_nil!), Store.null_int(input.category_id), input.paid_by,
            input.notes, input.reimbursement?, input.split_mode.value, input.amount_cents,
            input.original_amount_minor, input.original_currency, input.fx_rate, input.fx_source,
            Store.null_int(input.recurring_id), now, now)
        rescue ex
          raise RecurringExists.new if Store.unique_violation?(ex)
          raise ex
        end
        new_id = res.last_insert_id
        Store.insert_shares(tx, new_id, Store.split_shares(input, new_id))
        insert_activity(tx, actor_id, ACTION_EXPENSE_CREATED, new_id,
          ActivityDetails.new(title: input.title, amount_cents: input.amount_cents))
        new_id
      end
      notify(ExpenseChange.new(id, ACTION_EXPENSE_CREATED))
      id
    end

    # Logs the changed fields; an unchanged save writes nothing (not even
    # updated_at) and calls no hook.
    def update_expense(actor_id : Int64, id : Int64, input : ExpenseInput) : Nil
      input = Store.normalize_expense(input)
      shares = Store.split_shares(input, id)
      changed = transaction do |tx|
        old = Store.get_expense(tx, id)
        raise NotFound.new if old.deleted?
        Store.check_refs(tx, input)
        changes = Store.diff_expense(tx, old, input, shares)
        next false if changes.empty?
        begin
          tx.exec("UPDATE expenses SET title = ?, date = ?, category_id = ?, paid_by = ?, notes = ?, " \
                  "is_reimbursement = ?, split_mode = ?, amount_cents = ?, original_amount_minor = ?, " \
                  "original_currency = ?, fx_rate = ?, fx_source = ?, updated_at = ? WHERE id = ?",
            input.title, Store.format_date(input.date.not_nil!), Store.null_int(input.category_id), input.paid_by,
            input.notes, input.reimbursement?, input.split_mode.value, input.amount_cents,
            input.original_amount_minor, input.original_currency, input.fx_rate, input.fx_source, now_string, id)
        rescue ex
          # Unique index (recurring_id, date): here an input error.
          if Store.unique_violation?(ex)
            raise Domain::ValidationError.new("Für diesen Termin gibt es schon eine Ausgabe dieser Wiederholung.")
          end
          raise ex
        end
        tx.exec("DELETE FROM expense_shares WHERE expense_id = ?", id)
        Store.insert_shares(tx, id, shares)
        insert_activity(tx, actor_id, ACTION_EXPENSE_UPDATED, id,
          ActivityDetails.new(title: input.title, amount_cents: input.amount_cents, changes: changes))
        true
      end
      notify(ExpenseChange.new(id, ACTION_EXPENSE_UPDATED)) if changed
    end

    # Soft delete; the shares stay. Already deleted expenses raise NotFound.
    def delete_expense(actor_id : Int64, id : Int64) : Nil
      transaction do |tx|
        old = Store.get_expense(tx, id)
        raise NotFound.new if old.deleted?
        now = now_string
        tx.exec("UPDATE expenses SET deleted_at = ?, updated_at = ? WHERE id = ?", now, now, id)
        insert_activity(tx, actor_id, ACTION_EXPENSE_DELETED, id,
          ActivityDetails.new(title: old.title, amount_cents: old.amount_cents))
      end
      notify(ExpenseChange.new(id, ACTION_EXPENSE_DELETED))
    end

    # Deleted expenses too (the YNAB sync processes deletions).
    def get_expense(id : Int64) : Expense
      Store.get_expense(@db, id)
    end

    def self.get_expense(db : DB::QueryMethods, id : Int64) : Expense
      query_expenses(db, EXPENSE_SELECT + " WHERE e.id = ?", [id] of DB::Any).first? || raise NotFound.new
    end

    # Non-deleted expenses, by default newest first.
    def list_expenses(f : ExpenseFilter = ExpenseFilter.new) : Array(Expense)
      order = EXPENSE_ORDER[f.sort]? || raise ArgumentError.new("unknown sort order #{f.sort.inspect}")
      where = ["e.deleted_at IS NULL"]
      args = [] of DB::Any
      cond, cond_args = Store.text_cond([f.text] + f.any_text)
      unless cond.empty?
        where << cond
        args.concat(cond_args)
      end
      if f.without_category?
        where << "e.category_id IS NULL"
      elsif f.category_id != 0
        where << "e.category_id = ?"
        args << f.category_id
      end
      if f.participant_id != 0
        where << "(e.paid_by = ? OR EXISTS (SELECT 1 FROM expense_shares x WHERE x.expense_id = e.id AND x.participant_id = ?))"
        args << f.participant_id << f.participant_id
      end
      if f.paid_by != 0
        where << "e.paid_by = ?"
        args << f.paid_by
      end
      if f.involved_id != 0
        where << "EXISTS (SELECT 1 FROM expense_shares x WHERE x.expense_id = e.id AND x.participant_id = ?)"
        args << f.involved_id
      end
      if f.min_cents != 0
        where << "e.amount_cents >= ?"
        args << f.min_cents
      end
      if f.max_cents != 0
        where << "e.amount_cents <= ?"
        args << f.max_cents
      end
      if from = f.from
        where << "e.date >= ?"
        args << Store.format_date(from)
      end
      if to = f.to
        where << "e.date <= ?"
        args << Store.format_date(to)
      end
      q = EXPENSE_SELECT + " WHERE " + where.join(" AND ") + " ORDER BY " + order
      if f.limit > 0
        q += " LIMIT ? OFFSET ?"
        args << f.limit << f.offset
      end
      Store.query_expenses(@db, q, args)
    end

    # The ID the next new expense will most likely get (SQLite assigns
    # max(id) + 1; deletes are soft). The form preview needs it to distribute
    # leftover cents like the store; a concurrent create makes the preview off
    # by at most one cent.
    def next_expense_id : Int64
      @db.scalar("SELECT coalesce(max(id), 0) + 1 FROM expenses").as(Int64)
    end

    def balance_entries : Array(Domain::Entry)
      dated_balance_entries(nil).map(&.entry)
    end

    # Non-deleted expenses dated up to `to` (nil = all), oldest first.
    def dated_balance_entries(to : Time?) : Array(DatedEntry)
      q = "SELECT e.id, e.date, e.paid_by, e.amount_cents, x.participant_id, x.amount_cents " \
          "FROM expenses e JOIN expense_shares x ON x.expense_id = e.id WHERE e.deleted_at IS NULL"
      args = [] of DB::Any
      if to
        q += " AND e.date <= ?"
        args << Store.format_date(to)
      end
      entries = [] of DatedEntry
      last_id = 0_i64
      @db.query(q + " ORDER BY e.date, e.id, x.participant_id", args: args) do |rs|
        rs.each do
          id, date, paid_by, amount, pid, share = rs.read(Int64, String, Int64, Int64, Int64, Int64)
          if id != last_id
            entries << DatedEntry.new(Store.parse_date(date), Domain::Entry.new(paid_by, amount, [] of Domain::Share))
            last_id = id
          end
          entries.last.entry.shares << Domain::Share.new(participant_id: pid, amount_cents: share)
        end
      end
      entries
    end

    # Cents per person (positive = is owed money); people without entries are
    # missing.
    def balances : Hash(Int64, Int64)
      Domain.balances(balance_entries)
    end

    # sql must start with EXPENSE_SELECT.
    def self.query_expenses(db : DB::QueryMethods, sql : String, args : Array(DB::Any) = [] of DB::Any) : Array(Expense)
      expenses = [] of Expense
      db.query(sql, args: args) do |rs|
        rs.each do
          id = rs.read(Int64)
          title = rs.read(String)
          date_s = rs.read(String)
          date = begin
            parse_date(date_s)
          rescue ex
            raise Exception.new("expense #{id}: date #{date_s.inspect}: #{ex.message}")
          end
          input = ExpenseInput.new(
            title: title,
            date: date,
            category_id: rs.read(Int64?) || 0_i64,
            paid_by: rs.read(Int64),
            notes: rs.read(String),
            reimbursement: rs.read(Int64) != 0,
            split_mode: Domain::SplitMode.new(rs.read(String)),
            amount_cents: rs.read(Int64),
            original_amount_minor: rs.read(Int64),
            original_currency: rs.read(String),
            fx_rate: rs.read(Float64),
            fx_source: rs.read(String),
            recurring_id: rs.read(Int64?) || 0_i64,
          )
          expenses << Expense.new(id, input,
            created_at: parse_time(rs.read(String?)),
            updated_at: parse_time(rs.read(String?)),
            deleted_at: parse_time(rs.read(String?)),
            category_name: rs.read(String),
            paid_by_name: rs.read(String))
        end
      end
      shares = load_shares(db, expenses.map(&.id))
      expenses.map! do |e|
        e.shares = shares[e.id]? || [] of Domain::Share
        input = e.input
        input.parts = e.shares.map { |sh| Domain::Part.new(sh.participant_id, sh.weight) }
        e.input = input
        e
      end
    end

    protected def self.load_shares(db : DB::QueryMethods, ids : Array(Int64)) : Hash(Int64, Array(Domain::Share))
      by_id = {} of Int64 => Array(Domain::Share)
      ids.each_slice(500) do |chunk|
        db.query("SELECT expense_id, participant_id, weight, amount_cents FROM expense_shares " \
                 "WHERE expense_id IN (#{placeholders(chunk.size)}) ORDER BY expense_id, participant_id",
          args: chunk.map(&.as(DB::Any))) do |rs|
          rs.each do
            eid, pid, weight, cents = rs.read(Int64, Int64, Int64, Int64)
            (by_id[eid] ||= [] of Domain::Share) << Domain::Share.new(pid, weight, cents)
          end
        end
      end
      by_id
    end

    protected def self.diff_expense(tx : DB::Connection, old : Expense, input : ExpenseInput,
                                    shares : Array(Domain::Share)) : Array(FieldChange)
      names = participant_names(tx)
      changes = [] of FieldChange
      add = ->(field : String, o : String, n : String) do
        changes << FieldChange.new(field, o, n) if o != n
        nil
      end
      kind = ->(r : Bool) { r ? "Rückzahlung" : "Ausgabe" }
      add.call("Art", kind.call(old.reimbursement?), kind.call(input.reimbursement?))
      add.call("Titel", old.title, input.title)
      add.call("Betrag", Domain.format_cents(old.amount_cents), Domain.format_cents(input.amount_cents))
      add.call("Originalbetrag", Domain.format_money(old.original_amount_minor, old.original_currency),
        Domain.format_money(input.original_amount_minor, input.original_currency))
      add.call("Datum", Domain.format_date(old.date), Domain.format_date(input.date))
      if old.category_id != input.category_id
        new_cat = "–"
        if input.category_id != 0
          new_cat = tx.query_one("SELECT name FROM categories WHERE id = ?", input.category_id, as: String)
        end
        add.call("Kategorie", old.category_name.presence || "–", new_cat)
      end
      add.call("Bezahlt von", names[old.paid_by], names[input.paid_by])
      add.call("Notiz", old.notes, input.notes)
      add.call("Kurs", rate_summary(old.input), rate_summary(input))
      old_split = split_summary(old.split_mode, old.shares, names)
      new_split = split_summary(input.split_mode, shares, names)
      add.call("Aufteilung", old_split, new_split)
      if old_split == new_split
        # Same cents but different weights (e.g. shares 1:1 → 2:2).
        label = case input.split_mode
                when Domain::SPLIT_SHARES  then "Anteile"
                when Domain::SPLIT_PERCENT then "Prozente"
                when Domain::SPLIT_AMOUNT  then "Beträge"
                else                            "Gewichte"
                end
        add.call(label, weight_summary(old.split_mode, old.original_currency, old.shares, names),
          weight_summary(input.split_mode, input.original_currency, shares, names))
      end
      changes
    end

    # "1 € = 1,0857 USD (EZB)", or "–" without foreign currency.
    protected def self.rate_summary(input : ExpenseInput) : String
      return "–" if Domain.eur?(input.original_currency)
      s = "1 € = #{Domain.format_rate(input.fx_rate)} #{input.original_currency.upcase}"
      case input.fx_source
      when ""                    then s
      when Domain::FX_SOURCE_ECB then s + " (EZB)"
      else                            s + " (#{input.fx_source})"
      end
    end

    # The weights per person in the mode's format (amounts in currency).
    def self.weight_summary(mode : Domain::SplitMode, currency : String, shares : Array(Domain::Share),
                            names : Hash(Int64, String)) : String
      shares.join(", ") do |sh|
        w = case mode
            when Domain::SPLIT_PERCENT then Domain.format_basis_points(sh.weight)
            when Domain::SPLIT_AMOUNT  then Domain.format_money(sh.weight, currency)
            else                            sh.weight.to_s
            end
        "#{names[sh.participant_id]} #{w}"
      end
    end

    protected def self.split_summary(mode : Domain::SplitMode, shares : Array(Domain::Share), names : Hash(Int64, String)) : String
      "#{mode.label}: " + shares.join(", ") { |sh| "#{names[sh.participant_id]} #{Domain.format_cents(sh.amount_cents)}" }
    end

    # Unknown IDs map to "".
    protected def self.participant_names(tx : DB::Connection) : Hash(Int64, String)
      names = Hash(Int64, String).new("")
      tx.query("SELECT id, name FROM participants") do |rs|
        rs.each { names[rs.read(Int64)] = rs.read(String) }
      end
      names
    end

    protected def self.placeholders(n : Int) : String
      (["?"] * n).join(",")
    end
  end
end
