module Zipfelkasse
  class Store
    # Title and category of a past expense (for category suggestions).
    record TitleCategory, title : String, category_id : Int64

    # Writes the name even if unchanged, but logs only a change.
    def set_group_name(actor_id : Int64, name : String) : Nil
      name = Store.clean_name(name, "die Gruppe")
      transaction do |tx|
        old = tx.query_one?("SELECT value FROM settings WHERE key = ?", SETTING_GROUP_NAME, as: String)
        old = DEFAULT_GROUP_NAME if old.nil? || old.empty?
        tx.exec(SET_SETTING_SQL, SETTING_GROUP_NAME, name)
        log_settings(tx, actor_id, "Gruppe umbenannt: „#{old}“ → „#{name}“") unless old == name
      end
    end

    # Swaps an active category with its neighbour among the active ones and
    # renumbers them; at the edges nothing happens. Unknown or archived
    # categories raise NotFound.
    def move_category(actor_id : Int64, id : Int64, up : Bool) : Nil
      transaction do |tx|
        active = Store.active_categories(tx)
        ids = active.map(&.id)
        idx = ids.index(id) || raise NotFound.new
        other, dir = up ? {idx - 1, "oben"} : {idx + 1, "unten"}
        next unless 0 <= other < ids.size
        ids.swap(idx, other)
        Store.renumber_categories(tx, ids)
        log_settings(tx, actor_id, "Kategorie „#{active[idx].name}“ nach #{dir} verschoben")
      end
    end

    # Non-deleted expenses per category; categories without any are missing.
    def expense_count_by_category : Hash(Int64, Int32)
      count_by("SELECT category_id, count(*) FROM expenses " \
               "WHERE deleted_at IS NULL AND category_id IS NOT NULL GROUP BY category_id")
    end

    # Non-deleted expenses a person paid or has a share in.
    def expense_count_by_participant : Hash(Int64, Int32)
      count_by("SELECT pid, count(DISTINCT eid) FROM (" \
               "SELECT e.paid_by AS pid, e.id AS eid FROM expenses e WHERE e.deleted_at IS NULL " \
               "UNION ALL " \
               "SELECT x.participant_id, x.expense_id FROM expense_shares x " \
               "JOIN expenses e ON e.id = x.expense_id WHERE e.deleted_at IS NULL" \
               ") GROUP BY pid")
    end

    private def count_by(q : String) : Hash(Int64, Int32)
      counts = {} of Int64 => Int32
      @db.query(q) do |rs|
        rs.each { counts[rs.read(Int64)] = rs.read(Int64).to_i32 }
      end
      counts
    end

    # Non-deleted, non-reimbursement expenses with an active category, newest
    # first.
    def category_history : Array(TitleCategory)
      history = [] of TitleCategory
      @db.query("SELECT e.title, e.category_id FROM expenses e " \
                "JOIN categories c ON c.id = e.category_id " \
                "WHERE e.deleted_at IS NULL AND e.is_reimbursement = 0 AND c.archived_at IS NULL " \
                "ORDER BY e.date DESC, e.id DESC") do |rs|
        rs.each { history << TitleCategory.new(rs.read(String), rs.read(Int64)) }
      end
      history
    end
  end
end
