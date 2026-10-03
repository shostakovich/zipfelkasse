module Zipfelkasse
  class Store
    module Archivable
      def archived? : Bool
        !archived_at.nil?
      end
    end

    record Category, id : Int64, name : String, position : Int64, archived_at : Time? do
      include DB::Serializable
      include Archivable

      @[DB::Field(converter: Zipfelkasse::Store::TimeText)]
      @archived_at : Time?
    end

    CATEGORY_COLS = "id, name, position, archived_at"

    OTHER_CATEGORY = "Sonstiges"

    def list_categories(include_archived = false, db : DB::QueryMethods = @db) : Array(Category)
      where = include_archived ? "" : " WHERE archived_at IS NULL"
      db.query_all("SELECT #{CATEGORY_COLS} FROM categories#{where} ORDER BY position, name COLLATE NOCASE, id", as: Category)
    end

    def get_category?(id : Int64, db : DB::QueryMethods = @db) : Category?
      db.query_one?("SELECT #{CATEGORY_COLS} FROM categories WHERE id = ?", id, as: Category)
    end

    def get_category(id : Int64, db : DB::QueryMethods = @db) : Category
      get_category?(id, db) || raise NotFound.new
    end

    # New categories go before the active "Sonstiges", wherever it was moved to.
    def create_category(actor_id : Int64?, name : String) : Int64
      name = Store.clean_name(name, "die Kategorie")
      transaction do |tx|
        active = list_categories(db: tx)
        id = Store.on_duplicate("Die Kategorie „#{name}“ gibt es schon.") do
          tx.exec("INSERT INTO categories (name, position) VALUES (?, 0)", name).last_insert_id
        end
        at = active.index { |c| c.name.compare(OTHER_CATEGORY, case_insensitive: true) == 0 } || active.size
        ids = active.map(&.id)
        ids.insert(at, id)
        renumber_categories(tx, ids)
        log_settings(tx, actor_id, "Kategorie „#{name}“ hinzugefügt")
        id
      end
    end

    private def renumber_categories(tx : DB::Connection, ids : Array(Int64)) : Nil
      ids.each_with_index(1) do |id, i|
        tx.exec("UPDATE categories SET position = ? WHERE id = ?", i * 10, id)
      end
    end

    def rename_category(actor_id : Int64?, id : Int64, name : String) : Nil
      name = Store.clean_name(name, "die Kategorie")
      rename_row(actor_id, "categories", "Kategorie", id, name, "Die Kategorie „#{name}“ gibt es schon.")
    end

    def set_category_archived(actor_id : Int64?, id : Int64, archived : Bool) : Nil
      transaction do |tx|
        archive_row(tx, actor_id, "categories", "Kategorie", get_category(id, tx).name, id, archived)
      end
    end

    # At the edges nothing happens; archived categories raise NotFound.
    def move_category(actor_id : Int64?, id : Int64, up : Bool) : Nil
      transaction do |tx|
        active = list_categories(db: tx)
        ids = active.map(&.id)
        idx = ids.index(id) || raise NotFound.new
        other, dir = up ? {idx - 1, "oben"} : {idx + 1, "unten"}
        next unless 0 <= other < ids.size
        ids.swap(idx, other)
        renumber_categories(tx, ids)
        log_settings(tx, actor_id, "Kategorie „#{active[idx].name}“ nach #{dir} verschoben")
      end
    end

    def expense_count_by_category : Hash(Int64, Int32)
      @db.query_all("SELECT category_id, count(*) FROM expenses " \
                    "WHERE deleted_at IS NULL AND category_id IS NOT NULL GROUP BY category_id",
        as: {Int64, Int32}).to_h
    end
  end
end
