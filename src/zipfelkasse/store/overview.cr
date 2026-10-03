module Zipfelkasse
  class Store
    # An allowlist of the tables shown outside the app: the YNAB tables (token!) stay out.
    EXPOSED_TABLES = %w(participants categories expenses expense_shares recurring activity fx_rates settings)

    record SchemaObject, type : String, name : String, sql : String

    record DataOverview, expenses : Int64, reimbursements : Int64, without_category : Int64,
      first_date : Time?, last_date : Time?, activity_actions : Array(String)

    def schema : Array(SchemaObject)
      Store.schema_objects(@db, "main")
    end

    def self.schema_objects(db : DB::QueryMethods, schema : String) : Array(SchemaObject)
      objects = [] of SchemaObject
      db.query_each("SELECT type, name, tbl_name, sql FROM #{schema}.sqlite_schema " \
                    "WHERE type IN ('table', 'index') AND sql IS NOT NULL ORDER BY type DESC, rowid") do |rs|
        type, name, table, sql = rs.read(String, String, String, String)
        objects << SchemaObject.new(type, name, sql) if EXPOSED_TABLES.includes?(table)
      end
      objects
    end

    def overview : DataOverview
      expenses, reimbursements, without, first, last = @db.query_one(
        "SELECT coalesce(sum(is_reimbursement = 0), 0), coalesce(sum(is_reimbursement = 1), 0), " \
        "coalesce(sum(is_reimbursement = 0 AND category_id IS NULL), 0), min(date), max(date) " \
        "FROM expenses WHERE deleted_at IS NULL", as: {Int64, Int64, Int64, String?, String?})
      actions = @db.query_all("SELECT DISTINCT action FROM activity ORDER BY action", as: String)
      DataOverview.new(expenses, reimbursements, without,
        first.try { |d| Store.parse_date(d) }, last.try { |d| Store.parse_date(d) }, actions)
    end
  end
end
