module Zipfelkasse::Web
  ACTIVITY_PAGE_SIZE = 50

  # An activity entry prepared for display. verb is "" for actions other
  # than expense changes (shown with details.text); show_amount is set for
  # created and deleted expenses (amount changes are listed in the changes).
  record ActivityItem, activity : Store::Activity, verb : String, show_amount : Bool do
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
                            {"", false}
                          end
      ActivityItem.new(a, verb, show_amount)
    end
  end

  class Handlers
    def register_activity : Nil
      Web.route(@d, "GET", "/aktivitaet") { |r| activity(r) }
    end

    def activity(r : Request) : Nil
      before = Web.form_id?(r.query("vor"))
      acts = @d.store.list_activity(Store::ActivityFilter.new(before_id: before, limit: ACTIVITY_PAGE_SIZE + 1))
      more = ""
      if acts.size > ACTIVITY_PAGE_SIZE
        acts = acts[0, ACTIVITY_PAGE_SIZE]
        more = "/aktivitaet?vor=#{acts.last.id}"
      end
      today = @d.today
      loc = @d.config.location
      groups = Web.activity_items(acts).chunks { |item| Web.activity_period(Domain.date_of(item.at.in(loc)), today) }
      r.page(200, Page.new(title: "Aktivität", nav: NAV_ACTIVITY)) do |__io__|
        Web.template __io__, "web/activity.ecr"
      end
    end

    # The activity-item partial; link makes the entry a link to its expense.
    private def activity_item(__io__ : IO, a : ActivityItem, link : Bool) : Nil
      link &&= !a.expense_id.nil?
      Web.template __io__, "web/_activity.ecr"
    end
  end
end
