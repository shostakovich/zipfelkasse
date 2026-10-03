module Zipfelkasse::YNAB
  PAGE_PATH = "/einstellungen/ynab"

  record AccountOption, value : String, name : String, selected : Bool # value: "planID|accountID"
  record PlanOption, name : String, accounts : Array(AccountOption)
  record CategoryOption, id : String, name : String
  record GroupOption, name : String, categories : Array(CategoryOption)
  record CategoryRow, id : Int64, name : String, archived : Bool,
    selected : String, # YNAB category ID or ""
    missing : Bool     # the mapped YNAB category no longer exists

  # What the page shows. It deliberately never contains the token.
  class PageData
    property? token_set = false
    property? token_invalid = false
    property api_error = "" # YNAB unreachable or similar (the page stays usable)
    property plans = [] of PlanOption
    property plan_name = ""
    property account_name = ""
    property currency = "" # of the selected plan, if not EUR
    property? has_target = false
    property start_date : Time = Time.utc(1, 1, 1)
    property categories = [] of CategoryRow
    property groups = [] of GroupOption
    property? ready = false
    property status = Status.new
    property retry_at : Time? = nil # only if in the future
    property synced = 0
    property problems = [] of Store::YNABSyncProblem
    property balance = 0_i64 # own balance in the app
  end

  # Open, non-deleted on-budget accounts (only there can expenses be
  # categorized).
  def self.usable_accounts(p : APIPlan) : Array(APIAccount)
    p.accounts.select { |a| a.on_budget && !a.closed && !a.deleted }
  end

  # Visible categories without internal groups ("Inflow: Ready to Assign")
  # and without credit card payment categories (the API rejects those).
  def self.usable_groups(groups : Array(APICategoryGroup)) : Array(GroupOption)
    groups.compact_map do |g|
      next if g.internal || g.hidden || g.deleted || g.name == "Credit Card Payments"
      cats = g.categories.reject { |c| c.hidden || c.deleted || c.internal }.map { |c| CategoryOption.new(c.id, c.name) }
      GroupOption.new(g.name, cats) unless cats.empty?
    end
  end

  def self.known_categories(groups : Array(GroupOption)) : Set(String)
    groups.flat_map(&.categories.map(&.id)).to_set
  end

  # Names of plan and account for the activity log.
  def self.target_names(plans : Array(APIPlan), plan_id : String, account_id : String) : {String, String}
    plans.each do |p|
      next unless p.id == plan_id
      a = p.accounts.find(&.id.==(account_id))
      return {p.name, a ? a.name : account_id}
    end
    {plan_id, account_id}
  end

  def self.account_exists?(plans : Array(APIPlan), plan_id : String, account_id : String) : Bool
    p = plans.find(&.id.==(plan_id))
    !p.nil? && usable_accounts(p).any?(&.id.==(account_id))
  end

  # YNAB category names by ID, for the activity log.
  def self.category_names(groups : Array(APICategoryGroup)) : Hash(String, String)
    names = {} of String => String
    groups.each { |g| g.categories.each { |c| names[c.id] = c.name } }
    names
  end

  class Service
    include Web::Helpers

    def register : Nil
      Web.route(@d, "GET", PAGE_PATH) { |r| render(r, 200, "", r.query("neu") == "1") }
      Web.route(@d, "POST", PAGE_PATH + "/token") { |r| save_token(r) }
      Web.route(@d, "POST", PAGE_PATH + "/trennen") { |r| disconnect(r) }
      Web.route(@d, "POST", PAGE_PATH + "/konto") { |r| save_target(r) }
      Web.route(@d, "POST", PAGE_PATH + "/kategorien") { |r| save_categories(r) }
      Web.route(@d, "POST", PAGE_PATH + "/sync") { |r| sync_now(r) }
    end

    private def config_of(participant_id : Int64) : Store::YNABConfig?
      @d.store.get_ynab_config(participant_id)
    rescue Store::NotFound
      nil
    end

    # refresh reloads plans and categories from YNAB instead of the cache.
    private def render(r : Web::Request, status : Int32, error : String, refresh : Bool) : Nil
      me = r.me
      cfg = config_of(me.id) || YNAB.empty_config(me.id)
      data = PageData.new
      data.token_set = !cfg.token.empty?
      data.start_date = cfg.start_date || today
      data.ready = cfg.ready?
      data.has_target = !cfg.account_id.empty?
      data.status = load_status(me.id)
      data.token_invalid = data.token_set? && data.status.token_invalid?
      data.retry_at = data.status.retry_at.try { |t| t if t > @now.call }
      data.synced, data.problems = @d.store.ynab_sync_summary(me.id)
      data.balance = @d.store.balances[me.id]? || 0_i64

      if data.token_set? && !data.token_invalid?
        begin
          fill_plans(data, plans(cfg.token, refresh), cfg)
        rescue ex
          data.api_error = api_message(ex, cfg.token)
        end
        if !cfg.plan_id.empty? && data.api_error.empty?
          begin
            data.groups = YNAB.usable_groups(categories(cfg.token, cfg.plan_id, refresh))
          rescue ex
            data.api_error = api_message(ex, cfg.token)
          end
        end
      end
      data.categories = category_rows(me.id, data.groups) if data.has_target?
      r.page(status, Web::Page.new(title: "YNAB", nav: Web::NAV_SETTINGS, error: error)) do |__io__|
        Web.template __io__, "ynab/ynab.ecr"
      end
    end

    private def fill_plans(data : PageData, plans : Array(APIPlan), cfg : Store::YNABConfig) : Nil
      plans.each do |p|
        accounts = YNAB.usable_accounts(p).map do |a|
          selected = p.id == cfg.plan_id && a.id == cfg.account_id
          if selected
            data.plan_name, data.account_name = p.name, a.name
            data.currency = p.currency unless p.currency.empty? || p.currency == "EUR"
          end
          AccountOption.new(p.id + "|" + a.id, a.name, selected)
        end
        data.plans << PlanOption.new(p.name, accounts) unless accounts.empty?
      end
    end

    private def category_rows(participant_id : Int64, groups : Array(GroupOption)) : Array(CategoryRow)
      m = @d.store.ynab_category_map(participant_id)
      known = YNAB.known_categories(groups)
      @d.store.list_categories(true).compact_map do |c|
        selected = m[c.id]? || ""
        next if c.archived? && selected.empty?
        CategoryRow.new(c.id, c.name, c.archived?, selected,
          !selected.empty? && !groups.empty? && !known.includes?(selected))
      end
    end

    private def api_message(ex : Exception, token : String) : String
      return TOKEN_INVALID_MESSAGE if YNAB.status_of(ex) == 401
      "YNAB ist gerade nicht erreichbar: " + YNAB.redact(ex.message || "", token)
    end

    private def done(r : Web::Request, message : String) : Nil
      r.set_flash(message)
      r.redirect(PAGE_PATH)
    end

    # Checks the token with a request to YNAB and stores it. If the chosen
    # plan is not among the token's plans (token of another YNAB user), plan
    # and account are reset and have to be chosen anew.
    private def save_token(r : Web::Request) : Nil
      me = r.me
      token = r.form_value("token").strip
      if token.empty?
        return render(r, 422, "Bitte einen Token eingeben.", false)
      elsif token.bytesize > 200 || token.each_char.any?(&.in?(' ', '\t', '\r', '\n'))
        return render(r, 422, "Das sieht nicht wie ein YNAB-Token aus.", false)
      end
      plans = begin
        plans(token, true)
      rescue ex
        msg = YNAB.status_of(ex) == 401 ? "YNAB kennt diesen Token nicht. Bitte prüfen und neu kopieren." : api_message(ex, token)
        return render(r, 422, msg, false)
      end
      reachable = ->(plan_id : String) { plans.any?(&.id.==(plan_id)) }
      # also resets the rate-limit pause and old errors of the old token
      reset_target = change_connection { @d.store.set_ynab_token(me.id, token, reachable) }
      if reset_target
        return done(r, "Token gespeichert. Der bisher gewählte Plan ist mit diesem Token nicht erreichbar – bitte Plan und Konto neu wählen.")
      end
      trigger
      done(r, "Token gespeichert.")
    end

    private def disconnect(r : Web::Request) : Nil
      me = r.me
      change_connection { @d.store.set_ynab_token(me.id, "") }
      done(r, "YNAB-Verbindung getrennt. Die Buchungen in YNAB bleiben erhalten.")
    end

    private def save_target(r : Web::Request) : Nil
      me = r.me
      cfg = config_of(me.id)
      return render(r, 422, "Bitte zuerst einen Token eingeben.", false) if cfg.nil? || cfg.token.empty?
      plan_id, _, account_id = r.form_value("ziel").partition('|')
      start = begin
        Domain.parse_date(r.form_value("start"))
      rescue Domain::ValidationError
        return render(r, 422, "Bitte ein gültiges Startdatum angeben.", false)
      end
      plans = begin
        plans(cfg.token, false)
      rescue ex
        return render(r, 502, api_message(ex, cfg.token), false)
      end
      return render(r, 422, "Bitte Plan und Konto auswählen.", false) unless YNAB.account_exists?(plans, plan_id, account_id)
      plan_name, account_name = YNAB.target_names(plans, plan_id, account_id)
      change_connection do
        @d.store.set_ynab_target(me.id, Store::YNABTarget.new(plan_id, account_id, plan_name, account_name, start))
      end
      trigger
      done(r, "Gespeichert.")
    end

    private def save_categories(r : Web::Request) : Nil
      me = r.me
      cfg = config_of(me.id)
      if cfg.nil? || cfg.token.empty? || cfg.plan_id.empty?
        return render(r, 422, "Bitte zuerst Token, Plan und Konto einrichten.", false)
      end
      groups = begin
        categories(cfg.token, cfg.plan_id, false)
      rescue ex
        return render(r, 502, api_message(ex, cfg.token), false)
      end
      known = YNAB.known_categories(YNAB.usable_groups(groups))
      old = @d.store.ynab_category_map(me.id)
      m = {} of Int64 => String
      seen = Set(String).new
      r.body_params.each do |key, v|
        next unless seen.add?(key) && key.starts_with?("kat-")
        id = key.lchop("kat-").to_i64?(whitespace: false) || next
        # Unknown IDs are allowed only if they were mapped already (category
        # deleted or hidden in YNAB: do not silently lose the mapping).
        if !v.empty? && !known.includes?(v) && old[id]? != v
          return render(r, 422, "Unbekannte YNAB-Kategorie. Bitte die Seite neu laden.", false)
        end
        m[id] = v
      end
      begin
        @d.store.set_ynab_category_map(me.id, m, YNAB.category_names(groups))
      rescue ex : Domain::ValidationError
        return render(r, 422, ex.msg, false)
      end
      trigger
      done(r, "Kategorie-Zuordnung gespeichert.")
    end

    # Starts a full sync in the background and redirects right away; the
    # status shows the result after reloading.
    private def sync_now(r : Web::Request) : Nil
      me = r.me
      cfg = config_of(me.id)
      return render(r, 422, NOT_READY_MESSAGE, false) unless cfg && cfg.ready?
      sync_in_background(me.id)
      done(r, "Synchronisierung gestartet – Status unten aktualisiert sich nach dem Neuladen.")
    end
  end
end
