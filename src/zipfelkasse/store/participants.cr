module Zipfelkasse
  class Store
    # People are never deleted, only archived.
    record Participant, id : Int64, name : String, created_at : Time, archived_at : Time? do
      include DB::Serializable
      include Archivable

      @[DB::Field(converter: Zipfelkasse::Store::TimeText)]
      @created_at : Time
      @[DB::Field(converter: Zipfelkasse::Store::TimeText)]
      @archived_at : Time?
    end

    PARTICIPANT_COLS = "id, name, created_at, archived_at"

    def list_participants(include_archived = false) : Array(Participant)
      where = include_archived ? "" : " WHERE archived_at IS NULL"
      @db.query_all("SELECT #{PARTICIPANT_COLS} FROM participants#{where} ORDER BY name COLLATE NOCASE, id", as: Participant)
    end

    # Archived people too.
    def get_participant?(id : Int64, db : DB::QueryMethods = @db) : Participant?
      db.query_one?("SELECT #{PARTICIPANT_COLS} FROM participants WHERE id = ?", id, as: Participant)
    end

    def get_participant(id : Int64, db : DB::QueryMethods = @db) : Participant
      get_participant?(id, db) || raise NotFound.new
    end

    # Duplicate names (case-insensitive) raise a ValidationError.
    def create_participant(actor_id : Int64?, name : String) : Int64
      insert_participant(actor_id, false, name)
    end

    # Creates a person who adds themselves (who page, before they have an
    # identity): the activity entry names the new person as actor.
    def join_as_participant(name : String) : Int64
      insert_participant(nil, true, name)
    end

    private def insert_participant(actor_id : Int64?, self_actor : Bool, name : String) : Int64
      name = Store.clean_name(name, "die Person")
      transaction do |tx|
        id = Store.on_duplicate("„#{name}“ gibt es schon.") do
          tx.exec("INSERT INTO participants (name, created_at) VALUES (?, ?)", name, now_string).last_insert_id
        end
        log_settings(tx, self_actor ? id : actor_id, "Person „#{name}“ hinzugefügt")
        id
      end
    end

    def rename_participant(actor_id : Int64?, id : Int64, name : String) : Nil
      name = Store.clean_name(name, "die Person")
      transaction do |tx|
        old = get_participant(id, tx)
        Store.on_duplicate("„#{name}“ gibt es schon.") do
          tx.exec("UPDATE participants SET name = ? WHERE id = ?", name, id)
        end
        log_settings(tx, actor_id, "Person „#{old.name}“ umbenannt in „#{name}“") unless old.name == name
      end
    end

    # Archives or restores a person. A person with an open balance cannot be
    # archived (ValidationError); otherwise they would disappear from forms
    # while money is still owed. Check and archiving run in one transaction,
    # so that no expense can come in between.
    def set_participant_archived(actor_id : Int64?, id : Int64, archived : Bool) : Nil
      transaction do |tx|
        p = get_participant(id, tx)
        if archived
          balance = tx.scalar(
            "SELECT (SELECT coalesce(sum(amount_cents), 0) FROM expenses WHERE paid_by = ?1 AND deleted_at IS NULL) - " \
            "(SELECT coalesce(sum(x.amount_cents), 0) FROM expense_shares x JOIN expenses e ON e.id = x.expense_id " \
            "WHERE x.participant_id = ?1 AND e.deleted_at IS NULL)", id).as(Int64)
          if balance != 0
            raise Domain::ValidationError.new("#{p.name} hat noch einen Saldo von #{Domain.format_cents(balance)}. Bitte erst ausgleichen, dann archivieren.")
          end
        end
        verb, at = archived ? {"archiviert", now_string} : {"reaktiviert", nil}
        tx.exec("UPDATE participants SET archived_at = ? WHERE id = ?", at, id)
        log_settings(tx, actor_id, "Person „#{p.name}“ #{verb}")
      end
    end

    # Non-deleted expenses a person paid or has a share in.
    def expense_count_by_participant : Hash(Int64, Int32)
      @db.query_all("SELECT pid, count(DISTINCT eid) FROM (" \
                    "SELECT e.paid_by AS pid, e.id AS eid FROM expenses e WHERE e.deleted_at IS NULL " \
                    "UNION ALL " \
                    "SELECT x.participant_id, x.expense_id FROM expense_shares x " \
                    "JOIN expenses e ON e.id = x.expense_id WHERE e.deleted_at IS NULL" \
                    ") GROUP BY pid", as: {Int64, Int32}).to_h
    end
  end
end
