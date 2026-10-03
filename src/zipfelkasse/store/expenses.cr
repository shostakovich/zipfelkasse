require "json"

module Zipfelkasse
  class Store
    # Ties are broken newest first.
    enum ExpenseSort
      DateDesc
      DateAsc
      AmountDesc
      AmountAsc

      def order_sql : String
        case self
        in .date_desc?   then "e.date DESC, e.id DESC"
        in .date_asc?    then "e.date, e.id"
        in .amount_desc? then "e.amount_cents DESC, e.date DESC, e.id DESC"
        in .amount_asc?  then "e.amount_cents, e.date DESC, e.id DESC"
        end
      end
    end

    # An expense as entered, or the template of a recurrence (stored as JSON
    # without date and recurring_id). The store validates it and computes the
    # shares from split_mode, amounts and parts. For SplitMode::Amount the
    # weights are amounts in the smallest unit of original_currency.
    #
    # In euros original_amount_minor is amount_cents, fx_rate 1 and fx_source
    # nil; the store sets them. For a foreign currency it computes
    # amount_cents from original_amount_minor and fx_rate.
    struct ExpenseInput
      include JSON::Serializable

      property title : String = ""
      @[JSON::Field(ignore: true)]
      property date : Time?
      property category_id : Int64?
      property paid_by : Int64?
      property notes : String = ""
      @[JSON::Field(key: "is_reimbursement")]
      property? reimbursement : Bool = false
      property split_mode : Domain::SplitMode = Domain::SplitMode::Equal
      property amount_cents : Int64 = 0_i64
      property parts : Array(Domain::Part) = [] of Domain::Part
      property original_amount_minor : Int64 = 0_i64
      property original_currency : String = "EUR"
      property fx_rate : Float64?
      property fx_source : Domain::FXSource?
      @[JSON::Field(ignore: true)]
      property recurring_id : Int64?

      def initialize(*, @title = "", @date = nil, @category_id = nil, @paid_by = nil, @notes = "", @reimbursement = false,
                     @split_mode = Domain::SplitMode::Equal, @amount_cents = 0_i64, @parts = [] of Domain::Part,
                     @original_amount_minor = 0_i64, @original_currency = "EUR", @fx_rate = nil, @fx_source = nil,
                     @recurring_id = nil)
      end
    end

    # A stored expense, deleted ones included.
    record Expense,
      id : Int64,
      title : String,
      date : Time,
      category_id : Int64?,
      paid_by : Int64,
      notes : String,
      reimbursement : Bool,
      split_mode : Domain::SplitMode,
      amount_cents : Int64,
      original_amount_minor : Int64,
      original_currency : String,
      fx_rate : Float64,
      fx_source : Domain::FXSource?,
      recurring_id : Int64?,
      created_at : Time,
      updated_at : Time,
      deleted_at : Time?,
      category_name : String?,
      paid_by_name : String,
      shares : Array(Domain::Share) do
      include DB::Serializable

      @[DB::Field(converter: Zipfelkasse::Store::DateText)]
      @date : Time
      @[DB::Field(key: "is_reimbursement")]
      @reimbursement : Bool
      @[DB::Field(converter: Zipfelkasse::Store::FXSourceText)]
      @fx_source : Domain::FXSource?
      @[DB::Field(converter: Zipfelkasse::Store::TimeText)]
      @created_at : Time
      @[DB::Field(converter: Zipfelkasse::Store::TimeText)]
      @updated_at : Time
      @[DB::Field(converter: Zipfelkasse::Store::TimeText)]
      @deleted_at : Time?
      @[DB::Field(converter: Zipfelkasse::Store::JSONText(Array(Zipfelkasse::Domain::Share)))]
      @shares : Array(Domain::Share)

      def reimbursement? : Bool
        reimbursement
      end

      def deleted? : Bool
        !deleted_at.nil?
      end

      def foreign? : Bool
        !Domain.eur?(original_currency)
      end

      # Cents of participant_id's share, 0 if not involved.
      def share_of(participant_id : Int64) : Int64
        shares.find(&.participant_id.==(participant_id)).try(&.amount_cents) || 0_i64
      end

      def parts : Array(Domain::Part)
        shares.map { |sh| Domain::Part.new(sh.participant_id, sh.weight) }
      end

      # Complete (parts from the stored weights), so it can be passed straight
      # back to update_expense or become a template.
      def to_input : ExpenseInput
        ExpenseInput.new(title: title, date: date, category_id: category_id, paid_by: paid_by, notes: notes,
          reimbursement: reimbursement, split_mode: split_mode, amount_cents: amount_cents, parts: parts,
          original_amount_minor: original_amount_minor, original_currency: original_currency, fx_rate: fx_rate,
          fx_source: fx_source, recurring_id: recurring_id)
      end
    end

    # Narrows list_expenses; the defaults mean "no filter".
    record ExpenseFilter,
      text : String? = nil,                    # substring of title or notes, folded
      any_text : Array(String) = [] of String, # one of them suffices (together with text)
      category_id : Int64? = nil,
      without_category : Bool = false, # then category_id is ignored
      participant_id : Int64? = nil,   # paid or is involved
      paid_by : Int64? = nil,
      involved_id : Int64? = nil,
      min_cents : Int64? = nil,
      max_cents : Int64? = nil,
      from : Time? = nil, # inclusive
      to : Time? = nil,   # inclusive
      sort : ExpenseSort = ExpenseSort::DateDesc,
      limit : Int32? = nil,
      offset : Int32 = 0

    record DatedEntry, date : Time, entry : Domain::Entry

    # Title and category of a past expense (for category suggestions).
    record TitleCategory, title : String, category_id : Int64 do
      include DB::Serializable
    end

    EXPENSE_SELECT = <<-SQL
      SELECT e.id, e.title, e.date, e.category_id, e.paid_by, e.notes, e.is_reimbursement, e.split_mode,
        e.amount_cents, e.original_amount_minor, e.original_currency, e.fx_rate, e.fx_source, e.recurring_id,
        e.created_at, e.updated_at, e.deleted_at, c.name AS category_name, p.name AS paid_by_name,
        (SELECT json_group_array(json_object('participant_id', participant_id, 'weight', weight,
                                             'amount_cents', amount_cents))
           FROM (SELECT * FROM expense_shares WHERE expense_id = e.id ORDER BY participant_id)) AS shares
      FROM expenses e
      LEFT JOIN categories c ON c.id = e.category_id
      JOIN participants p ON p.id = e.paid_by
      SQL

    # As maxlength in the expense form.
    MAX_TITLE_LEN =  200
    MAX_NOTES_LEN = 2000

    # "Title or notes of e contain one of terms", compared folded (LIKE would
    # only ignore the case of ASCII letters). Empty without terms.
    protected def self.text_cond(terms : Enumerable(String)) : {String, Array(DB::Any)}
      ors = [] of String
      args = [] of DB::Any
      terms.each do |t|
        t = t.strip.downcase(:fold)
        next if t.empty?
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
      raise Domain::ValidationError.new("Bitte einen Titel angeben.") if input.title.empty?
      raise Domain::ValidationError.new("Der Titel ist zu lang (höchstens #{MAX_TITLE_LEN} Zeichen).") if input.title.size > MAX_TITLE_LEN
      # Browsers count a line break as one character for maxlength but send
      # it as CR LF.
      if input.notes.gsub("\r\n", "\n").size > MAX_NOTES_LEN
        raise Domain::ValidationError.new("Die Notiz ist zu lang (höchstens #{MAX_NOTES_LEN} Zeichen).")
      end
      date = input.date || raise Domain::ValidationError.new("Bitte ein Datum angeben.")
      paid_by = input.paid_by
      raise Domain::ValidationError.new("Bitte angeben, wer bezahlt hat.") if paid_by.nil? || paid_by <= 0
      input.date = Domain.date_of(date)
      if input.reimbursement?
        raise Domain::ValidationError.new("Eine Rückzahlung geht an genau eine Person.") if input.parts.size != 1
        if input.parts[0].participant_id == paid_by
          raise Domain::ValidationError.new("Bei einer Rückzahlung müssen Zahler und Empfänger verschieden sein.")
        end
        input.split_mode = Domain::SplitMode::Equal
      end
      if Domain.eur?(input.original_currency)
        input.original_currency = "EUR"
        input.original_amount_minor = input.amount_cents
        input.fx_rate = 1.0
        input.fx_source = nil
      else
        cur = input.original_currency.strip.upcase
        input.original_currency = cur
        raise Domain::ValidationError.new("Ungültige Währung „#{cur}“.") unless Domain.valid_currency_code?(cur)
        raise Domain::ValidationError.new("Bitte den Betrag in #{cur} angeben.") if input.original_amount_minor <= 0
        rate = input.fx_rate
        raise Domain::ValidationError.new("Bitte einen Wechselkurs für #{cur} angeben.") if rate.nil? || rate <= 0
        input.amount_cents = Domain.to_eur_cents(input.original_amount_minor, cur, rate)
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
    private def check_refs(tx : DB::Connection, input : ExpenseInput) : Nil
      ids = ([input.paid_by.not_nil!] + input.parts.map(&.participant_id)).uniq!.sort!
      n = tx.scalar("SELECT count(*) FROM participants WHERE id IN (#{Store.placeholders(ids.size)})",
        args: ids.map(&.as(DB::Any))).as(Int64)
      raise Domain::ValidationError.new("Unbekannte Person in der Ausgabe.") if n != ids.size
      if category_id = input.category_id
        raise Domain::ValidationError.new("Unbekannte Kategorie.") unless get_category?(category_id, tx)
      end
    end

    private def insert_shares(tx : DB::Connection, expense_id : Int64, shares : Array(Domain::Share)) : Nil
      shares.each do |sh|
        tx.exec("INSERT INTO expense_shares (expense_id, participant_id, weight, amount_cents) VALUES (?, ?, ?, ?)",
          expense_id, sh.participant_id, sh.weight, sh.amount_cents)
      end
    end

    # No actor means the system. The text is shown with the activity entry.
    def create_expense(actor_id : Int64?, input : ExpenseInput, text : String? = nil) : Int64
      input = Store.normalize_expense(input)
      id = transaction do |tx|
        check_refs(tx, input)
        if recurring_id = input.recurring_id
          # Same transaction as the insert: a recurrence paused or deleted
          # meanwhile gets no instance (instead of a foreign key error).
          active = tx.query_one?("SELECT active FROM recurring WHERE id = ?", recurring_id, as: Int64)
          raise RecurringChanged.new if active.nil? || active == 0
        end
        now = now_string
        new_id = Store.on_duplicate(RecurringExists.new) do
          tx.exec("INSERT INTO expenses (title, date, category_id, paid_by, notes, is_reimbursement, split_mode, " \
                  "amount_cents, original_amount_minor, original_currency, fx_rate, fx_source, recurring_id, " \
                  "created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            input.title, Store.format_date(input.date.not_nil!), input.category_id, input.paid_by, input.notes,
            input.reimbursement?, input.split_mode.key, input.amount_cents, input.original_amount_minor,
            input.original_currency, input.fx_rate, input.fx_source.try(&.key) || "", recurring_id, now, now).last_insert_id
        end
        insert_shares(tx, new_id, Store.split_shares(input, new_id))
        insert_activity(tx, actor_id, Action::ExpenseCreated, new_id,
          ActivityDetails.new(title: input.title, amount_cents: input.amount_cents, text: text))
        new_id
      end
      changed(id)
      id
    end

    # Logs the changed fields; an unchanged save writes nothing (not even
    # updated_at) and calls no hook.
    def update_expense(actor_id : Int64?, id : Int64, input : ExpenseInput) : Nil
      input = Store.normalize_expense(input)
      shares = Store.split_shares(input, id)
      changed = transaction do |tx|
        old = get_expense(id, tx)
        raise NotFound.new if old.deleted?
        check_refs(tx, input)
        changes = diff_expense(tx, old, input, shares)
        next false if changes.empty?
        Store.on_duplicate("Für diesen Termin gibt es schon eine Ausgabe dieser Wiederholung.") do
          tx.exec("UPDATE expenses SET title = ?, date = ?, category_id = ?, paid_by = ?, notes = ?, " \
                  "is_reimbursement = ?, split_mode = ?, amount_cents = ?, original_amount_minor = ?, " \
                  "original_currency = ?, fx_rate = ?, fx_source = ?, updated_at = ? WHERE id = ?",
            input.title, Store.format_date(input.date.not_nil!), input.category_id, input.paid_by, input.notes,
            input.reimbursement?, input.split_mode.key, input.amount_cents, input.original_amount_minor,
            input.original_currency, input.fx_rate, input.fx_source.try(&.key) || "", now_string, id)
        end
        tx.exec("DELETE FROM expense_shares WHERE expense_id = ?", id)
        insert_shares(tx, id, shares)
        insert_activity(tx, actor_id, Action::ExpenseUpdated, id,
          ActivityDetails.new(title: input.title, amount_cents: input.amount_cents, changes: changes))
        true
      end
      changed(id) if changed
    end

    # Soft delete; the shares stay. Already deleted expenses raise NotFound.
    def delete_expense(actor_id : Int64?, id : Int64) : Nil
      transaction do |tx|
        old = get_expense(id, tx)
        raise NotFound.new if old.deleted?
        now = now_string
        tx.exec("UPDATE expenses SET deleted_at = ?, updated_at = ? WHERE id = ?", now, now, id)
        insert_activity(tx, actor_id, Action::ExpenseDeleted, id,
          ActivityDetails.new(title: old.title, amount_cents: old.amount_cents))
      end
      changed(id)
    end

    # Deleted expenses too (the YNAB sync processes deletions).
    def get_expense?(id : Int64, db : DB::QueryMethods = @db) : Expense?
      db.query_one?("#{EXPENSE_SELECT} WHERE e.id = ?", id, as: Expense)
    end

    def get_expense(id : Int64, db : DB::QueryMethods = @db) : Expense
      get_expense?(id, db) || raise NotFound.new
    end

    # Non-deleted expenses, by default newest first.
    def list_expenses(f : ExpenseFilter = ExpenseFilter.new) : Array(Expense)
      where = ["e.deleted_at IS NULL"]
      args = [] of DB::Any
      cond, cond_args = Store.text_cond([f.text || ""] + f.any_text)
      unless cond.empty?
        where << cond
        args.concat(cond_args)
      end
      if f.without_category
        where << "e.category_id IS NULL"
      elsif id = f.category_id
        where << "e.category_id = ?"
        args << id
      end
      if id = f.participant_id
        where << "(e.paid_by = ? OR EXISTS (SELECT 1 FROM expense_shares x WHERE x.expense_id = e.id AND x.participant_id = ?))"
        args << id << id
      end
      if id = f.paid_by
        where << "e.paid_by = ?"
        args << id
      end
      if id = f.involved_id
        where << "EXISTS (SELECT 1 FROM expense_shares x WHERE x.expense_id = e.id AND x.participant_id = ?)"
        args << id
      end
      if cents = f.min_cents
        where << "e.amount_cents >= ?"
        args << cents
      end
      if cents = f.max_cents
        where << "e.amount_cents <= ?"
        args << cents
      end
      if from = f.from
        where << "e.date >= ?"
        args << Store.format_date(from)
      end
      if to = f.to
        where << "e.date <= ?"
        args << Store.format_date(to)
      end
      q = "#{EXPENSE_SELECT} WHERE #{where.join(" AND ")} ORDER BY #{f.sort.order_sql}"
      if limit = f.limit
        q += " LIMIT ? OFFSET ?"
        args << limit << f.offset
      end
      @db.query_all(q, args: args, as: Expense)
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

    # Non-deleted, non-reimbursement expenses with an active category, newest
    # first.
    def category_history : Array(TitleCategory)
      @db.query_all("SELECT e.title, e.category_id FROM expenses e JOIN categories c ON c.id = e.category_id " \
                    "WHERE e.deleted_at IS NULL AND e.is_reimbursement = 0 AND c.archived_at IS NULL " \
                    "ORDER BY e.date DESC, e.id DESC", as: TitleCategory)
    end

    private def diff_expense(tx : DB::Connection, old : Expense, input : ExpenseInput,
                             shares : Array(Domain::Share)) : Array(FieldChange)
      names = participant_names(tx)
      kind = ->(reimbursement : Bool) { reimbursement ? Domain::REIMBURSEMENT_TITLE : "Ausgabe" }
      old_split = split_summary(old.split_mode, old.shares, names)
      new_split = split_summary(input.split_mode, shares, names)
      fields = [
        {"Art", kind.call(old.reimbursement?), kind.call(input.reimbursement?)},
        {"Titel", old.title, input.title},
        {"Betrag", Domain.format_cents(old.amount_cents), Domain.format_cents(input.amount_cents)},
        {"Originalbetrag", Domain.format_money(old.original_amount_minor, old.original_currency),
         Domain.format_money(input.original_amount_minor, input.original_currency)},
        {"Datum", Domain.format_date(old.date), Domain.format_date(input.date.not_nil!)},
      ]
      if old.category_id != input.category_id
        new_category = input.category_id.try { |id| get_category(id, tx).name }
        fields << {"Kategorie", old.category_name || "–", new_category || "–"}
      end
      fields << {"Bezahlt von", names[old.paid_by], names[input.paid_by]}
      fields << {"Notiz", old.notes, input.notes}
      fields << {"Kurs", rate_summary(old.original_currency, old.fx_rate, old.fx_source),
                 rate_summary(input.original_currency, input.fx_rate, input.fx_source)}
      fields << {"Aufteilung", old_split, new_split}
      if old_split == new_split
        # Same cents but different weights (e.g. shares 1:1 → 2:2).
        label = case input.split_mode
                in .shares?  then "Anteile"
                in .percent? then "Prozente"
                in .amount?  then "Beträge"
                in .equal?   then "Gewichte"
                end
        fields << {label, Store.weight_summary(old.split_mode, old.original_currency, old.shares, names),
                   Store.weight_summary(input.split_mode, input.original_currency, shares, names)}
      end
      fields.select { |_, was, now| was != now }.map { |field, was, now| FieldChange.new(field, was, now) }
    end

    # "1 € = 1,0857 USD (EZB)", or "–" without foreign currency.
    private def rate_summary(currency : String, rate : Float64?, source : Domain::FXSource?) : String
      return "–" if Domain.eur?(currency)
      summary = "1 € = #{Domain.format_rate(rate.not_nil!)} #{currency.upcase}"
      case source
      in Nil               then summary
      in .ecb?             then summary + " (EZB)"
      in .manual?, .fixed? then summary + " (#{source.key})"
      end
    end

    # The weights per person in the mode's format (amounts in currency).
    def self.weight_summary(mode : Domain::SplitMode, currency : String, shares : Array(Domain::Share),
                            names : Hash(Int64, String)) : String
      shares.join(", ") do |sh|
        w = case mode
            in .percent?         then Domain.format_basis_points(sh.weight)
            in .amount?          then Domain.format_money(sh.weight, currency)
            in .equal?, .shares? then sh.weight.to_s
            end
        "#{names[sh.participant_id]} #{w}"
      end
    end

    # Persisted activity text: German, whatever the UI labels say later.
    private def split_summary(mode : Domain::SplitMode, shares : Array(Domain::Share), names : Hash(Int64, String)) : String
      label = case mode
              in .equal?   then "Gleichmäßig"
              in .shares?  then "Nach Anteilen"
              in .percent? then "Nach Prozent"
              in .amount?  then "Nach Beträgen"
              end
      "#{label}: " + shares.join(", ") { |sh| "#{names[sh.participant_id]} #{Domain.format_cents(sh.amount_cents)}" }
    end

    private def participant_names(tx : DB::Connection) : Hash(Int64, String)
      tx.query_all("SELECT id, name FROM participants", as: {Int64, String}).to_h
    end

    protected def self.placeholders(n : Int) : String
      (["?"] * n).join(",")
    end
  end
end
