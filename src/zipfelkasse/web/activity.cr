module Zipfelkasse::Web
  ACTIVITY_PAGE_SIZE = 50

  # verb is nil for other actions than expense changes (they show details.text).
  record ActivityItem, activity : Store::Activity, verb : String?, show_amount : Bool do
    delegate id, at, action, expense_id, details, to: @activity

    def actor : String
      @activity.actor_name || "Automatisch"
    end

    def amount_cents : Int64
      details.amount_cents || 0_i64
    end
  end

  def self.activity_items(acts : Array(Store::Activity)) : Array(ActivityItem)
    acts.map do |a|
      has_amount = !a.details.amount_cents.nil?
      verb, show_amount = case a.action
                          in .expense_created? then {"angelegt", has_amount}
                          in .expense_updated? then {"geändert", false}
                          in .expense_deleted? then {"gelöscht", has_amount}
                          in .settings_updated?, .recurring_created?, .recurring_deleted?
                            {nil, false}
                          end
      ActivityItem.new(a, verb, show_amount)
    end
  end

  module Views
    record ActivityEntry, a : ActivityItem, linked : Bool do
      Web.view "web/activity_entry.ecr"

      def link : Bool
        linked && !a.expense_id.nil?
      end
    end

    record Activity, groups : Array({String, Array(ActivityItem)}), more : String? do
      Web.view "web/activity.ecr"
    end
  end

  class ActivityController < Controller
    def register : Nil
      get("/aktivitaet") { |env| list(env) }
    end

    private def list(env : HTTP::Server::Context) : String
      before = Web.positive_id?(env.query("vor"), trim: true)
      acts = @d.store.list_activity(Store::ActivityFilter.new(before_id: before, limit: ACTIVITY_PAGE_SIZE + 1))
      more = nil
      if acts.size > ACTIVITY_PAGE_SIZE
        acts = acts[0, ACTIVITY_PAGE_SIZE]
        more = "/aktivitaet?vor=#{acts.last.id}"
      end
      today = @d.today
      groups = Web.activity_items(acts).chunks { |item| Web.period_label(Domain.date_of(item.at.in(@d.config.location)), today, activity: true) }
      page(env, Views::Activity.new(groups, more), "Aktivität", Nav::Activity)
    end
  end
end
