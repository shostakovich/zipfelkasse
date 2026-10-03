module Zipfelkasse
  class Store
    CATEGORY_COLS = "id, name, position, archived_at"

    # The catch-all category: new categories are sorted in before it,
    # wherever it has been moved to.
    OTHER_CATEGORY = "Sonstiges"

    protected def self.read_category(rs : DB::ResultSet) : Category
      Category.new(rs.read(Int64), rs.read(String), rs.read(Int64), parse_time(rs.read(String?)))
    end

    # In display order.
    def list_categories(include_archived = false) : Array(Category)
      q = "SELECT #{CATEGORY_COLS} FROM categories"
      q += " WHERE archived_at IS NULL" unless include_archived
      q += " ORDER BY position, name COLLATE NOCASE, id"
      out = [] of Category
      @db.query(q) { |rs| rs.each { out << Store.read_category(rs) } }
      out
    end

    # Archived categories too; raises NotFound.
    def get_category(id : Int64) : Category
      Store.get_category(@db, id)
    end

    def self.get_category(db : DB::QueryMethods, id : Int64) : Category
      db.query("SELECT #{CATEGORY_COLS} FROM categories WHERE id = ?", id) do |rs|
        rs.each { return read_category(rs) }
      end
      raise NotFound.new
    end

    # Inserts the category directly before the active "Sonstiges" (or at the
    # end without one) and renumbers the active categories.
    def create_category(actor_id : Int64, name : String) : Int64
      name = Store.clean_name(name, "die Kategorie")
      transaction do |tx|
        active = Store.active_categories(tx)
        id = begin
          tx.exec("INSERT INTO categories (name, position) VALUES (?, 0)", name).last_insert_id
        rescue ex
          raise Domain::ValidationError.new("Die Kategorie „#{name}“ gibt es schon.") if Store.unique_violation?(ex)
          raise ex
        end
        at = active.index { |c| c.name.compare(OTHER_CATEGORY, case_insensitive: true) == 0 } || active.size
        ids = active.map(&.id)
        ids.insert(at, id)
        Store.renumber_categories(tx, ids)
        log_settings(tx, actor_id, "Kategorie „#{name}“ hinzugefügt")
        id
      end
    end

    # In display order.
    protected def self.active_categories(db : DB::QueryMethods) : Array(Category)
      out = [] of Category
      db.query("SELECT #{CATEGORY_COLS} FROM categories WHERE archived_at IS NULL ORDER BY position, name COLLATE NOCASE, id") do |rs|
        rs.each { out << read_category(rs) }
      end
      out
    end

    # Positions 10, 20, … in the order of ids.
    protected def self.renumber_categories(tx : DB::Connection, ids : Array(Int64)) : Nil
      ids.each_with_index(1) do |id, i|
        tx.exec("UPDATE categories SET position = ? WHERE id = ?", i * 10, id)
      end
    end

    def rename_category(actor_id : Int64, id : Int64, name : String) : Nil
      name = Store.clean_name(name, "die Kategorie")
      transaction do |tx|
        old = Store.get_category(tx, id)
        begin
          tx.exec("UPDATE categories SET name = ? WHERE id = ?", name, id)
        rescue ex
          raise Domain::ValidationError.new("Die Kategorie „#{name}“ gibt es schon.") if Store.unique_violation?(ex)
          raise ex
        end
        log_settings(tx, actor_id, "Kategorie „#{old.name}“ umbenannt in „#{name}“") unless old.name == name
      end
    end

    # Logs even when the state does not change.
    def set_category_archived(actor_id : Int64, id : Int64, archived : Bool) : Nil
      verb, at = archived ? {"archiviert", now_string} : {"reaktiviert", nil}
      transaction do |tx|
        c = Store.get_category(tx, id)
        tx.exec("UPDATE categories SET archived_at = ? WHERE id = ?", at, id)
        log_settings(tx, actor_id, "Kategorie „#{c.name}“ #{verb}")
      end
    end
  end
end
