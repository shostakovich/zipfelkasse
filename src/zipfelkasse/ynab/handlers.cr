module Zipfelkasse::YNAB
  PAGE_PATH = "/einstellungen/ynab"

  record AccountOption, value : String, name : String, selected : Bool # value: "planID|accountID"
  record PlanOption, name : String, accounts : Array(AccountOption)
  record CategoryOption, id : String, name : String
  record GroupOption, name : String, categories : Array(CategoryOption)
  record CategoryRow, id : Int64, name : String, archived : Bool,
    selected : String?, # YNAB category ID
    missing : Bool      # the mapped YNAB category no longer exists

  # What the page shows. It deliberately never contains the token.
  record PageData,
    token_set : Bool,
    token_invalid : Bool,
    api_error : String?, # YNAB unreachable or similar (the page stays usable)
    plans : Array(PlanOption),
    currency : String?, # of the selected plan, if not EUR
    has_target : Bool,
    start_date : String,
    categories : Array(CategoryRow),
    groups : Array(GroupOption),
    ready : Bool,
    status : Status,
    retry_at : Time?, # only if in the future
    synced : Int32,
    problems : Array(Store::YNABSyncProblem),
    balance : Int64 # own balance in the app

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

  module Views
    record Index, data : PageData do
      Web.view "ynab/index.ecr"
    end
  end

  class Handlers < Web::Controller
    def initialize(deps : Web::Deps, @service : Service)
      super(deps)
    end

    def register : Nil
      get(PAGE_PATH) { |env| show(env, 200, nil, env.query("neu") == "1") }
      post(PAGE_PATH + "/token") { |env| save_token(env) }
      post(PAGE_PATH + "/trennen") { |env| disconnect(env) }
      post(PAGE_PATH + "/konto") { |env| save_target(env) }
      post(PAGE_PATH + "/kategorien") { |env| save_categories(env) }
      post(PAGE_PATH + "/sync") { |env| sync_now(env) }
    end

    # refresh reloads plans and categories from YNAB instead of the cache.
    private def show(env : HTTP::Server::Context, status : Int32, error : String?, refresh : Bool) : String
      me = env.me
      config = @d.store.get_ynab_config?(me.id) || YNAB.empty_config(me.id)
      token = config.token
      state = @service.load_status(me.id)
      token_invalid = !token.nil? && state.token_invalid?
      plans = [] of PlanOption
      groups = [] of GroupOption
      currency = api_error = nil
      if token && !token_invalid
        begin
          plans, currency = plan_options(@service.plans(token, refresh), config)
        rescue ex
          api_error = api_message(ex, token)
        end
        if (plan_id = config.plan_id) && api_error.nil?
          begin
            groups = YNAB.usable_groups(@service.categories(token, plan_id, refresh))
          rescue ex
            api_error = api_message(ex, token)
          end
        end
      end
      has_target = !config.account_id.nil?
      synced, problems = @d.store.ynab_sync_summary(me.id)
      data = PageData.new(token_set: !token.nil?, token_invalid: token_invalid, api_error: api_error, plans: plans,
        currency: currency, has_target: has_target, start_date: Store.format_date(config.start_date || @service.today),
        categories: has_target ? category_rows(me.id, groups) : [] of CategoryRow, groups: groups, ready: config.ready?,
        status: state, retry_at: state.retry_at.try { |t| t if t > @service.now.call }, synced: synced, problems: problems,
        balance: @d.store.balances[me.id]? || 0_i64)
      page(env, Views::Index.new(data), "YNAB", Web::Nav::Settings, status, error)
    end

    # The selectable accounts per plan, and the currency of the selected plan
    # if it is not EUR.
    private def plan_options(plans : Array(APIPlan), config : Store::YNABConfig) : {Array(PlanOption), String?}
      currency = nil
      options = plans.compact_map do |plan|
        accounts = YNAB.usable_accounts(plan).map do |account|
          selected = plan.id == config.plan_id && account.id == config.account_id
          currency = plan.currency if selected && !plan.currency.empty? && plan.currency != "EUR"
          AccountOption.new(plan.id + "|" + account.id, account.name, selected)
        end
        PlanOption.new(plan.name, accounts) unless accounts.empty?
      end
      {options, currency}
    end

    private def category_rows(participant_id : Int64, groups : Array(GroupOption)) : Array(CategoryRow)
      mapping = @d.store.ynab_category_map(participant_id)
      known = YNAB.known_categories(groups)
      @d.store.list_categories(true).compact_map do |category|
        selected = mapping[category.id]?.presence
        next if category.archived? && selected.nil?
        CategoryRow.new(category.id, category.name, category.archived?, selected,
          !selected.nil? && !groups.empty? && !known.includes?(selected))
      end
    end

    private def api_message(ex : Exception, token : String) : String
      return TOKEN_INVALID_MESSAGE if Failure.of(ex).unauthorized?
      "YNAB ist gerade nicht erreichbar: " + YNAB.redact(ex.message || "", token)
    end

    private def done(env : HTTP::Server::Context, message : String) : String
      redirect(env, PAGE_PATH, message)
    end

    # Checks the token with a request to YNAB and stores it. If the chosen
    # plan is not among the token's plans (token of another YNAB user), plan
    # and account are reset and have to be chosen anew.
    private def save_token(env : HTTP::Server::Context) : String
      me = env.me
      token = env.form("token").strip
      if token.empty?
        return show(env, 422, "Bitte einen Token eingeben.", false)
      elsif token.bytesize > 200 || token.each_char.any?(&.in?(' ', '\t', '\r', '\n'))
        return show(env, 422, "Das sieht nicht wie ein YNAB-Token aus.", false)
      end
      plans = begin
        @service.plans(token, true)
      rescue ex
        message = Failure.of(ex).unauthorized? ? "YNAB kennt diesen Token nicht. Bitte prüfen und neu kopieren." : api_message(ex, token)
        return show(env, 422, message, false)
      end
      # also resets the rate-limit pause and old errors of the old token
      reset_target = @service.change_connection { @d.store.set_ynab_token(me.id, token, plans.to_set(&.id)) }
      if reset_target
        return done(env, "Token gespeichert. Der bisher gewählte Plan ist mit diesem Token nicht erreichbar – bitte Plan und Konto neu wählen.")
      end
      @service.trigger
      done(env, "Token gespeichert.")
    end

    private def disconnect(env : HTTP::Server::Context) : String
      me = env.me
      @service.change_connection { @d.store.set_ynab_token(me.id, nil) }
      done(env, "YNAB-Verbindung getrennt. Die Buchungen in YNAB bleiben erhalten.")
    end

    private def save_target(env : HTTP::Server::Context) : String
      me = env.me
      token = @d.store.get_ynab_config?(me.id).try(&.token)
      return show(env, 422, "Bitte zuerst einen Token eingeben.", false) unless token
      plan_id, _, account_id = env.form("ziel").partition('|')
      start = begin
        Domain.parse_date(env.form("start"))
      rescue Domain::ValidationError
        return show(env, 422, "Bitte ein gültiges Startdatum angeben.", false)
      end
      plans = begin
        @service.plans(token, false)
      rescue ex
        return show(env, 502, api_message(ex, token), false)
      end
      return show(env, 422, "Bitte Plan und Konto auswählen.", false) unless YNAB.account_exists?(plans, plan_id, account_id)
      plan_name, account_name = YNAB.target_names(plans, plan_id, account_id)
      @service.change_connection do
        @d.store.set_ynab_target(me.id, Store::YNABTarget.new(plan_id, account_id, plan_name, account_name, start))
      end
      @service.trigger
      done(env, "Gespeichert.")
    end

    private def save_categories(env : HTTP::Server::Context) : String
      me = env.me
      config = @d.store.get_ynab_config?(me.id)
      token, plan_id = config.try(&.token), config.try(&.plan_id)
      return show(env, 422, "Bitte zuerst Token, Plan und Konto einrichten.", false) unless token && plan_id
      groups = begin
        @service.categories(token, plan_id, false)
      rescue ex
        return show(env, 502, api_message(ex, token), false)
      end
      known = YNAB.known_categories(YNAB.usable_groups(groups))
      old = @d.store.ynab_category_map(me.id)
      mapping = {} of Int64 => String
      seen = Set(String).new
      env.params.body.each do |key, value|
        next unless seen.add?(key) && key.starts_with?("kat-")
        id = key.lchop("kat-").to_i64?(whitespace: false) || next
        # Unknown IDs are allowed only if they were mapped already (category
        # deleted or hidden in YNAB: do not silently lose the mapping).
        if !value.empty? && !known.includes?(value) && old[id]? != value
          return show(env, 422, "Unbekannte YNAB-Kategorie. Bitte die Seite neu laden.", false)
        end
        mapping[id] = value
      end
      begin
        @d.store.set_ynab_category_map(me.id, mapping, YNAB.category_names(groups))
      rescue ex : Domain::ValidationError
        return show(env, 422, ex.msg, false)
      end
      @service.trigger
      done(env, "Kategorie-Zuordnung gespeichert.")
    end

    # Starts a full sync in the background and redirects right away; the
    # status shows the result after reloading.
    private def sync_now(env : HTTP::Server::Context) : String
      me = env.me
      config = @d.store.get_ynab_config?(me.id)
      return show(env, 422, NOT_READY_MESSAGE, false) unless config && config.ready?
      @service.sync_in_background(me.id)
      done(env, "Synchronisierung gestartet – Status unten aktualisiert sich nach dem Neuladen.")
    end
  end
end
