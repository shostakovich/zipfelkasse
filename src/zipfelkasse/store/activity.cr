require "json"

module Zipfelkasse
  class Store
    enum Action
      ExpenseCreated
      ExpenseUpdated
      ExpenseDeleted
      SettingsUpdated # people, categories, rates, recurrences, YNAB; the details carry the text
      RecurringCreated
      RecurringDeleted

      def key : String
        to_s.underscore
      end
    end

    # A changed property, already formatted for display (German field names,
    # formatted values).
    record FieldChange, field : String, old : String, new : String do
      include JSON::Serializable
    end

    # The content of activity.details_json; fields that are not set are left out.
    struct ActivityDetails
      include JSON::Serializable

      getter title : String?
      getter amount_cents : Int64?
      @[JSON::Field(ignore_serialize: @changes.empty?)]
      getter changes : Array(FieldChange) = [] of FieldChange
      getter text : String?

      def initialize(@title = nil, @amount_cents = nil, @changes = [] of FieldChange, @text = nil)
      end

      def self.from_rs(rs : DB::ResultSet) : ActivityDetails
        from_json(rs.read(String))
      rescue JSON::ParseException | JSON::SerializableError
        new
      end
    end

    record Activity,
      id : Int64,
      at : Time,
      actor_id : Int64?,
      actor_name : String?,
      action : Action,
      expense_id : Int64?,
      details : ActivityDetails do
      include DB::Serializable

      @[DB::Field(converter: Zipfelkasse::Store::TimeText)]
      @at : Time
      @[DB::Field(key: "details_json", converter: Zipfelkasse::Store::ActivityDetails)]
      @details : ActivityDetails
    end

    record ActivityFilter,
      expense_id : Int64? = nil,
      actor_id : Int64? = nil,
      action : Action? = nil,
      since : Time? = nil,      # at or after
      until : Time? = nil,      # before
      before_id : Int64? = nil, # for paging: only entries with a smaller ID
      limit : Int32 = 100

    # Writes an activity entry in the transaction of the change it describes.
    # No actor means the system.
    def insert_activity(tx : DB::Connection, actor_id : Int64?, action : Action, expense_id : Int64?,
                        details : ActivityDetails) : Nil
      tx.exec("INSERT INTO activity (at, actor_id, action, expense_id, details_json) VALUES (?, ?, ?, ?, ?)",
        now_string, actor_id, action.key, expense_id, details.to_json)
    end

    def log_settings(tx : DB::Connection, actor_id : Int64?, text : String) : Nil
      insert_activity(tx, actor_id, Action::SettingsUpdated, nil, ActivityDetails.new(text: text))
    end

    def list_activity(f : ActivityFilter = ActivityFilter.new) : Array(Activity)
      where = [] of String
      args = [] of DB::Any
      if id = f.expense_id
        where << "a.expense_id = ?"
        args << id
      end
      if id = f.actor_id
        where << "a.actor_id = ?"
        args << id
      end
      if action = f.action
        where << "a.action = ?"
        args << action.key
      end
      if since = f.since
        where << "a.at >= ?"
        args << Store.format_time(since)
      end
      if until_ = f.until
        where << "a.at < ?"
        args << Store.format_time(until_)
      end
      if id = f.before_id
        where << "a.id < ?"
        args << id
      end
      q = "SELECT a.id, a.at, a.actor_id, p.name AS actor_name, a.action, a.expense_id, a.details_json " \
          "FROM activity a LEFT JOIN participants p ON p.id = a.actor_id"
      q += " WHERE " + where.join(" AND ") unless where.empty?
      @db.query_all(q + " ORDER BY a.id DESC LIMIT ?", args: args + [f.limit.to_i64.as(DB::Any)], as: Activity)
    end
  end
end
