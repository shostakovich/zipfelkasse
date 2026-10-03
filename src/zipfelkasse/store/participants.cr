module Zipfelkasse
  class Store
    # People are never deleted, only archived. look and theme are their choice
    # of appearance for the web app.
    record Participant, id : Int64, name : String, created_at : Time, archived_at : Time?,
      look : String = "clean", theme : String = "auto" do
      include DB::Serializable
      include Archivable

      @[DB::Field(converter: Zipfelkasse::Store::TimeText)]
      @created_at : Time
      @[DB::Field(converter: Zipfelkasse::Store::TimeText)]
      @archived_at : Time?
    end

    PARTICIPANT_COLS = "id, name, created_at, archived_at, look, theme"

    def list_participants(include_archived = false) : Array(Participant)
      where = include_archived ? "" : " WHERE archived_at IS NULL"
      @db.query_all("SELECT #{PARTICIPANT_COLS} FROM participants#{where} ORDER BY name COLLATE NOCASE, id", as: Participant)
    end

    def get_participant?(id : Int64, db : DB::QueryMethods = @db) : Participant?
      db.query_one?("SELECT #{PARTICIPANT_COLS} FROM participants WHERE id = ?", id, as: Participant)
    end

    def get_participant(id : Int64, db : DB::QueryMethods = @db) : Participant
      get_participant?(id, db) || raise NotFound.new
    end

    def create_participant(actor_id : Int64?, name : String) : Int64
      insert_participant(actor_id, false, name)
    end

    # The activity entry names the new person as actor.
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
      rename_row(actor_id, "participants", "Person", id, name, "„#{name}“ gibt es schon.")
    end

    # A personal preference, not a change to the group: no activity entry.
    def set_appearance(id : Int64, look : String, theme : String) : Nil
      @db.exec("UPDATE participants SET look = ?, theme = ? WHERE id = ?", look, theme, id)
    end

    # A person with an open balance would disappear from the forms while money
    # is still owed, so archiving refuses.
    def set_participant_archived(actor_id : Int64?, id : Int64, archived : Bool) : Nil
      transaction do |tx|
        p = get_participant(id, tx)
        if archived && (balance = balances(tx).fetch(id, 0_i64)) != 0
          raise Domain::ValidationError.new("#{p.name} hat noch einen Saldo von #{Domain.format_cents(balance)}. Bitte erst ausgleichen, dann archivieren.")
        end
        archive_row(tx, actor_id, "participants", "Person", p.name, id, archived)
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

    private def rename_row(actor_id : Int64?, table : String, kind : String, id : Int64, name : String, duplicate : String) : Nil
      transaction do |tx|
        old = tx.query_one?("SELECT name FROM #{table} WHERE id = ?", id, as: String) || raise NotFound.new
        Store.on_duplicate(duplicate) { tx.exec("UPDATE #{table} SET name = ? WHERE id = ?", name, id) }
        log_settings(tx, actor_id, "#{kind} „#{old}“ umbenannt in „#{name}“") unless old == name
      end
    end

    # Logs even when the state does not change.
    private def archive_row(tx : DB::Connection, actor_id : Int64?, table : String, kind : String, name : String,
                            id : Int64, archived : Bool) : Nil
      tx.exec("UPDATE #{table} SET archived_at = ? WHERE id = ?", archived ? now_string : nil, id)
      log_settings(tx, actor_id, "#{kind} „#{name}“ #{archived ? "archiviert" : "reaktiviert"}")
    end
  end
end
