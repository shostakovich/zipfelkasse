module Zipfelkasse
  class Config
    class Error < Exception
    end

    TEST_HOOKS = {{ flag?(:test_hooks) }}

    # Anthropic's address range.
    DEFAULT_MCP_ALLOWED_CIDRS = "160.79.104.0/21"

    property addr : String = ":8080"
    property db_path : String = "./data/zipfelkasse.db"
    property mcp_secret : String = ""
    property mcp_allowed_cidrs : Array(Prefix) = Prefix.parse_list(DEFAULT_MCP_ALLOWED_CIDRS)
    property trusted_proxies = [] of Prefix
    property ecb_base_url : String?
    property ynab_base_url : String?
    property ynab_delay : Time::Span? = nil
    setter backup_dir : String?
    setter now : Time?

    property location : Time::Location = Time::Location.load_local

    def location_name : String
      location.name
    end

    def backup_dir : String
      @backup_dir || Path.new(File.dirname(db_path), "backups").normalize.to_s
    end

    def now : Time
      @now || Time.utc
    end

    def today : Time
      Domain.date_of(now.in(location))
    end

    def self.from_env(env = ENV) : Config
      c = new
      c.addr = value(env, "ZIPFELKASSE_ADDR") || c.addr
      c.db_path = value(env, "ZIPFELKASSE_DB") || c.db_path
      c.backup_dir = value(env, "ZIPFELKASSE_BACKUP_DIR")
      c.mcp_secret = value(env, "MCP_SECRET") || ""
      if v = value(env, "MCP_ALLOWED_CIDRS")
        c.mcp_allowed_cidrs = parse("MCP_ALLOWED_CIDRS") { Prefix.parse_list(v) }
      end
      c.trusted_proxies = parse("TRUSTED_PROXIES") { Prefix.parse_list(env["TRUSTED_PROXIES"]? || "") }
      if tz = value(env, "TZ")
        c.location = parse("TZ") { Time::Location.load(tz) }
      end
      c.read_test_hooks(env) if TEST_HOOKS
      c
    end

    def read_test_hooks(env) : Nil
      if v = Config.value(env, "ZIPFELKASSE_TEST_NOW")
        @now = Config.parse("ZIPFELKASSE_TEST_NOW") { Time.parse_rfc3339(v) }
      end
      @ecb_base_url = Config.value(env, "ZIPFELKASSE_TEST_ECB_URL")
      @ynab_base_url = Config.value(env, "ZIPFELKASSE_TEST_YNAB_URL")
      if v = Config.value(env, "ZIPFELKASSE_TEST_YNAB_DELAY_MS")
        @ynab_delay = Config.parse("ZIPFELKASSE_TEST_YNAB_DELAY_MS") do
          (v.to_i? || raise ArgumentError.new("not a whole number of milliseconds: #{v.inspect}")).milliseconds
        end
      end
    end

    protected def self.value(env, name : String) : String?
      env[name]?.try(&.strip).presence
    end

    protected def self.parse(name : String, &)
      yield
    rescue ex
      raise Error.new("invalid #{name}", cause: ex)
    end
  end
end
