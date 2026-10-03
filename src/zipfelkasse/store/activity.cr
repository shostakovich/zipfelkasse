require "json"

module Zipfelkasse
  class Store
    # Activity log actions. Feature packages may add their own actions (e.g.
    # "recurring_created"); the activity page shows unknown actions using
    # Details#text.
    ACTION_EXPENSE_CREATED = "expense_created"
    ACTION_EXPENSE_UPDATED = "expense_updated"
    ACTION_EXPENSE_DELETED = "expense_deleted"
    # Settings changed (people, categories, rates, recurrences, YNAB …);
    # Details#text describes the change.
    ACTION_SETTINGS_UPDATED = "settings_updated"
    # A migration recomputed the cent shares of existing expenses (system).
    ACTION_SHARES_RECALCULATED = "shares_recalculated"
    # A migration converted the weights of existing expenses (system).
    ACTION_WEIGHTS_CONVERTED = "weights_converted"

    # A changed property, already formatted for display (German field names,
    # formatted values).
    record FieldChange, field : String, old : String, new : String

    # The content of activity.details_json. Written like Go's encoding/json
    # with omitempty on every field.
    record ActivityDetails,
      title : String = "",          # expense title (as of after the action)
      amount_cents : Int64 = 0_i64, # expense amount
      changes : Array(FieldChange) = [] of FieldChange, # for expense_updated
      text : String = "" do         # free-form description for other actions
      def to_go_json : String
        GoCompat::JSON.build do |j|
          j.object do
            j.field "title", title unless title.empty?
            j.field "amount_cents", amount_cents unless amount_cents == 0
            unless changes.empty?
              j.field "changes" do
                j.array do
                  changes.each do |c|
                    j.object do
                      j.field "field", c.field
                      j.field "old", c.old
                      j.field "new", c.new
                    end
                  end
                end
              end
            end
            j.field "text", text unless text.empty?
          end
        end
      end

      # Reads details_json leniently like Go's json.Unmarshal (keys match
      # case-insensitively; broken JSON gives empty details).
      def self.parse(json : String) : ActivityDetails
        h = ::JSON.parse(json).as_h? || return new
        get = ->(key : String) { h.find { |k, _| k.compare(key, case_insensitive: true) == 0 }.try(&.[1]) }
        changes = (get.call("changes").try(&.as_a?) || [] of ::JSON::Any).compact_map do |c|
          ch = c.as_h? || next
          f = ->(key : String) { ch.find { |k, _| k.compare(key, case_insensitive: true) == 0 }.try(&.[1].as_s?) || "" }
          FieldChange.new(f.call("field"), f.call("old"), f.call("new"))
        end
        new(
          title: get.call("title").try(&.as_s?) || "",
          amount_cents: get.call("amount_cents").try(&.as_i64?) || 0_i64,
          changes: changes,
          text: get.call("text").try(&.as_s?) || "",
        )
      rescue ::JSON::ParseException
        new
      end
    end

    # An entry in the activity log.
    record Activity,
      id : Int64,
      at : Time?,
      actor_id : Int64,   # 0 = system
      actor_name : String, # "" for system
      action : String,
      expense_id : Int64, # 0 = not related to an expense
      details : ActivityDetails

    # Narrows `list_activity`.
    record ActivityFilter,
      expense_id : Int64 = 0_i64, # only entries for this expense
      actor_id : Int64 = 0_i64,   # only entries by this person
      action : String = "",       # only entries with this action
      since : Time? = nil,        # only entries at or after since
      until : Time? = nil,        # … and before until (nil = open)
      before_id : Int64 = 0_i64,  # for paging: only entries with a smaller ID
      limit : Int32 = 0           # 0 = 100

    # Writes an activity entry in the transaction of the change it describes.
    def insert_activity(tx : DB::Connection, actor_id : Int64, action : String, expense_id : Int64, details : ActivityDetails) : Nil
      tx.exec("INSERT INTO activity (at, actor_id, action, expense_id, details_json) VALUES (?, ?, ?, ?, ?)",
        now_string, Store.null_int(actor_id), action, Store.null_int(expense_id), details.to_go_json)
    end

    # Writes an ACTION_SETTINGS_UPDATED entry with text.
    def log_settings(tx : DB::Connection, actor_id : Int64, text : String) : Nil
      insert_activity(tx, actor_id, ACTION_SETTINGS_UPDATED, 0_i64, ActivityDetails.new(text: text))
    end

    # The newest entries first.
    def list_activity(f : ActivityFilter = ActivityFilter.new) : Array(Activity)
      where = [] of String
      args = [] of DB::Any
      if f.expense_id != 0
        where << "a.expense_id = ?"
        args << f.expense_id
      end
      if f.actor_id != 0
        where << "a.actor_id = ?"
        args << f.actor_id
      end
      unless f.action.empty?
        where << "a.action = ?"
        args << f.action
      end
      # at is RFC 3339 in UTC, so it compares as text.
      if since = f.since
        where << "a.at >= ?"
        args << since.to_utc.to_s(TIME_FORMAT)
      end
      if until_ = f.until
        where << "a.at < ?"
        args << until_.to_utc.to_s(TIME_FORMAT)
      end
      if f.before_id != 0
        where << "a.id < ?"
        args << f.before_id
      end
      limit = f.limit <= 0 ? 100 : f.limit
      q = "SELECT a.id, a.at, a.actor_id, coalesce(p.name, ''), a.action, a.expense_id, a.details_json " \
          "FROM activity a LEFT JOIN participants p ON p.id = a.actor_id"
      q += " WHERE " + where.join(" AND ") unless where.empty?
      q += " ORDER BY a.id DESC LIMIT ?"
      args << limit
      out = [] of Activity
      @db.query(q, args: args) do |rs|
        rs.each do
          out << Activity.new(
            id: rs.read(Int64),
            at: Store.parse_time(rs.read(String?)),
            actor_id: rs.read(Int64?) || 0_i64,
            actor_name: rs.read(String),
            action: rs.read(String),
            expense_id: rs.read(Int64?) || 0_i64,
            details: ActivityDetails.parse(rs.read(String)),
          )
        end
      end
      out
    end

    # 0 → NULL (IDs).
    def self.null_int(v : Int64) : Int64?
      v == 0 ? nil : v
    end
  end
end
