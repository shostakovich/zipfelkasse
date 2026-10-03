require "socket"

module Zipfelkasse
  struct Config
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
    property ecb_base_url : String = ""
    property ynab_base_url : String = ""
    property ynab_delay : Time::Span? = nil
    setter backup_dir : String?
    setter now : Time?

    getter location : Time::Location = Time::Location.local
    getter location_name = "Local"

    def location=(@location : Time::Location)
      @location_name = location.name
    end

    def backup_dir : String
      @backup_dir || Path.new(File.dirname(db_path), "backups").normalize.to_s
    end

    def now : Time
      @now || Time.utc
    end

    def today : Time
      t = now.in(location)
      Time.utc(t.year, t.month, t.day)
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
      @ecb_base_url = Config.value(env, "ZIPFELKASSE_TEST_ECB_URL") || ""
      @ynab_base_url = Config.value(env, "ZIPFELKASSE_TEST_YNAB_URL") || ""
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

    # An IP network (CIDR), always masked.
    struct Prefix
      getter bytes : Bytes
      getter bits : Int32

      def initialize(@bytes, @bits)
      end

      # Comma- or whitespace-separated; single IP addresses become /32 or /128.
      def self.parse_list(s : String) : Array(Prefix)
        s.split(/[, \t\n]/, remove_empty: true).map { |f| parse(f) }
      end

      def self.parse(s : String) : Prefix
        if s.includes?('/')
          addr, _, len = s.partition('/')
          bytes = Prefix.addr_bytes(addr) || raise ArgumentError.new("#{addr.inspect} is not an IP address")
          n = len.to_i? if len.matches?(/\A\d+\z/)
          raise ArgumentError.new("#{len.inspect} is not a valid prefix length for #{addr}") if n.nil? || n > bytes.size * 8
          new(mask(bytes, n), n)
        else
          bytes = Prefix.addr_bytes(s) || raise ArgumentError.new("#{s.inspect} is not an IP address or network")
          bytes = unmap(bytes)
          new(bytes, bytes.size * 8)
        end
      end

      def contains?(addr : String) : Bool
        if b = Prefix.addr_bytes(addr)
          contains?(b)
        else
          false
        end
      end

      def contains?(b : Bytes) : Bool
        b = Prefix.unmap(b)
        return false unless b.size == @bytes.size
        Prefix.mask(b, @bits) == @bytes
      end

      def to_s(io : IO) : Nil
        if @bytes.size == 4
          io << @bytes.join('.')
        else
          fields = StaticArray(UInt16, 8).new { |i| (@bytes[2 * i].to_u16 << 8) | @bytes[2 * i + 1] }
          io << Socket::IPAddress.v6(fields, port: 0_u16).address
        end
        io << '/' << @bits
      end

      def self.addr_bytes(s : String) : Bytes?
        return nil if s.includes?('%') # zones are not supported
        if s.matches?(/\A\d{1,3}(\.\d{1,3}){3}\z/)
          return nil if s.split('.').any? { |p| p.size > 1 && p.starts_with?('0') } # leading zeros would be ambiguous (octal)
          fields = Socket::IPAddress.parse_v4_fields?(s) || return nil
          Bytes.new(4) { |i| fields[i] }
        elsif s.includes?(':')
          fields = Socket::IPAddress.parse_v6_fields?(s) || return nil
          Bytes.new(16) { |i| (i.even? ? fields[i // 2] >> 8 : fields[i // 2] & 0xff).to_u8 }
        end
      end

      # IPv4-mapped IPv6 (::ffff:a.b.c.d) → IPv4.
      def self.unmap(b : Bytes) : Bytes
        if b.size == 16 && b[0, 10].all?(&.zero?) && b[10] == 0xff && b[11] == 0xff
          b[12, 4].dup
        else
          b
        end
      end

      def self.mask(b : Bytes, bits : Int32) : Bytes
        Bytes.new(b.size) do |i|
          keep = (bits - i * 8).clamp(0, 8)
          b[i] & (keep == 0 ? 0_u8 : (0xff_u8 << (8 - keep)))
        end
      end

      def ==(other : Prefix) : Bool
        @bits == other.bits && @bytes == other.bytes
      end
    end
  end
end
