module Zipfelkasse
  class Store
    # A person in the group. People are never deleted, only archived.
    record Participant, id : Int64, name : String, created_at : Time?, archived_at : Time? do
      def archived? : Bool
        !archived_at.nil?
      end
    end

    PARTICIPANT_COLS = "id, name, created_at, archived_at"

    protected def self.read_participant(rs : DB::ResultSet) : Participant
      Participant.new(rs.read(Int64), rs.read(String), parse_time(rs.read(String?)), parse_time(rs.read(String?)))
    end

    # People alphabetically, archived ones only on request.
    def list_participants(include_archived = false) : Array(Participant)
      q = "SELECT #{PARTICIPANT_COLS} FROM participants"
      q += " WHERE archived_at IS NULL" unless include_archived
      q += " ORDER BY name COLLATE NOCASE, id"
      out = [] of Participant
      @db.query(q) { |rs| rs.each { out << Store.read_participant(rs) } }
      out
    end

    # A person (archived ones too); raises NotFound.
    def get_participant(id : Int64) : Participant
      Store.get_participant(@db, id)
    end

    # Reads a person on db or inside a transaction.
    def self.get_participant(db : DB::QueryMethods, id : Int64) : Participant
      db.query("SELECT #{PARTICIPANT_COLS} FROM participants WHERE id = ?", id) do |rs|
        rs.each { return read_participant(rs) }
      end
      raise NotFound.new
    end

    # Creates a person, with actor_id as the actor of the activity entry.
    # Duplicate names (case-insensitive) raise a ValidationError.
    def create_participant(actor_id : Int64, name : String) : Int64
      create_participant(actor_id, false, name)
    end

    # Creates a person who adds themselves (who page, before they have an
    # identity): the activity entry names the new person as actor.
    def join_as_participant(name : String) : Int64
      create_participant(0_i64, true, name)
    end

    private def create_participant(actor_id : Int64, self_actor : Bool, name : String) : Int64
      name = Store.clean_name(name, "die Person")
      transaction do |tx|
        id = begin
          tx.exec("INSERT INTO participants (name, created_at) VALUES (?, ?)", name, now_string).last_insert_id
        rescue ex
          raise Domain::ValidationError.new("„#{name}“ gibt es schon.") if Store.unique_violation?(ex)
          raise ex
        end
        log_settings(tx, self_actor ? id : actor_id, "Person „#{name}“ hinzugefügt")
        id
      end
    end

    # Renames a person. Only an actual change of the name is logged.
    def rename_participant(actor_id : Int64, id : Int64, name : String) : Nil
      name = Store.clean_name(name, "die Person")
      transaction do |tx|
        old = Store.get_participant(tx, id)
        begin
          tx.exec("UPDATE participants SET name = ? WHERE id = ?", name, id)
        rescue ex
          raise Domain::ValidationError.new("„#{name}“ gibt es schon.") if Store.unique_violation?(ex)
          raise ex
        end
        log_settings(tx, actor_id, "Person „#{old.name}“ umbenannt in „#{name}“") unless old.name == name
      end
    end

    # Archives or restores a person. A person with an open balance cannot be
    # archived (ValidationError); otherwise they would disappear from forms
    # while money is still owed. Check and archiving run in one transaction,
    # so that no expense can come in between.
    def set_participant_archived(actor_id : Int64, id : Int64, archived : Bool) : Nil
      transaction do |tx|
        p = Store.get_participant(tx, id)
        verb, at = "reaktiviert", nil.as(String?)
        if archived
          balance = tx.scalar(
            "SELECT (SELECT coalesce(sum(amount_cents), 0) FROM expenses WHERE paid_by = ?1 AND deleted_at IS NULL) - " \
            "(SELECT coalesce(sum(x.amount_cents), 0) FROM expense_shares x JOIN expenses e ON e.id = x.expense_id " \
            "WHERE x.participant_id = ?1 AND e.deleted_at IS NULL)", id).as(Int64)
          if balance != 0
            raise Domain::ValidationError.new("#{p.name} hat noch einen Saldo von #{Domain.format_cents(balance)}. Bitte erst ausgleichen, dann archivieren.")
          end
          verb, at = "archiviert", now_string
        end
        tx.exec("UPDATE participants SET archived_at = ? WHERE id = ?", at, id)
        log_settings(tx, actor_id, "Person „#{p.name}“ #{verb}")
      end
    end

    # Raises NotFound when an UPDATE/DELETE changed no row.
    def self.check_affected(result : DB::ExecResult) : Nil
      raise NotFound.new if result.rows_affected == 0
    end
  end
end
