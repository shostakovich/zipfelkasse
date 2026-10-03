require "socket"

module Zipfelkasse
  # The complete runtime configuration, read from environment variables.
  struct Config
    # Anthropic's address range.
    DEFAULT_MCP_ALLOWED_CIDRS = "160.79.104.0/21"

    property addr : String = ":8080"                       # ZIPFELKASSE_ADDR
    property db_path : String = "./data/zipfelkasse.db"    # ZIPFELKASSE_DB (container: /data/zipfelkasse.db)
    property backup_dir : String = "data/backups"          # ZIPFELKASSE_BACKUP_DIR, default <directory of the DB>/backups
    property mcp_secret : String = ""                      # MCP_SECRET; empty = MCP disabled
    property mcp_allowed_cidrs = [] of Prefix              # MCP_ALLOWED_CIDRS, default 160.79.104.0/21
    property trusted_proxies = [] of Prefix                # TRUSTED_PROXIES (IPs or CIDRs), default empty
    property location : Time::Location = Time::Location.local # from TZ

    # Test-only overrides for the black-box E2E suite (e2e/). Never set them
    # in production.
    property now : Time? = nil                  # ZIPFELKASSE_TEST_NOW (RFC 3339): frozen clock
    property ecb_base_url : String = ""         # ZIPFELKASSE_TEST_ECB_URL
    property ynab_base_url : String = ""        # ZIPFELKASSE_TEST_YNAB_URL
    property ynab_delay : Time::Span? = nil     # ZIPFELKASSE_TEST_YNAB_DELAY

    class Error < Exception
    end

    def initialize
    end

    # The current time: the frozen test clock or the real one.
    def now : Time
      @now || Time.utc
    end

    def frozen_now : Time?
      @now
    end

    # Today's calendar date in the configured time zone (UTC midnight).
    def today : Time
      t = now.in(location)
      Time.utc(t.year, t.month, t.day)
    end

    def self.from_env(env = ENV) : Config
      c = Config.new
      c.addr = presence(env["ZIPFELKASSE_ADDR"]?) || ":8080"
      c.db_path = presence(env["ZIPFELKASSE_DB"]?) || "./data/zipfelkasse.db"
      c.mcp_secret = (env["MCP_SECRET"]? || "").strip
      c.backup_dir = presence(env["ZIPFELKASSE_BACKUP_DIR"]?) || clean_join(File.dirname(c.db_path), "backups")
      c.mcp_allowed_cidrs = wrap("MCP_ALLOWED_CIDRS") { Prefix.parse_list(presence(env["MCP_ALLOWED_CIDRS"]?) || DEFAULT_MCP_ALLOWED_CIDRS) }
      c.trusted_proxies = wrap("TRUSTED_PROXIES") { Prefix.parse_list(env["TRUSTED_PROXIES"]? || "") }
      if (tz = env["TZ"]?) && !tz.empty?
        c.location = wrap("TZ") { Time::Location.load(tz) }
      end
      c.test_overrides(env)
      c
    end

    protected def test_overrides(env) : Nil
      if v = Config.presence(env["ZIPFELKASSE_TEST_NOW"]?)
        @now = Config.wrap("ZIPFELKASSE_TEST_NOW") { Time.parse_rfc3339(v) }
      end
      @ecb_base_url = (env["ZIPFELKASSE_TEST_ECB_URL"]? || "").strip
      @ynab_base_url = (env["ZIPFELKASSE_TEST_YNAB_URL"]? || "").strip
      if v = Config.presence(env["ZIPFELKASSE_TEST_YNAB_DELAY"]?)
        @ynab_delay = Config.wrap("ZIPFELKASSE_TEST_YNAB_DELAY") { Config.parse_duration(v) }
      end
    end

    # Name of the time zone as Go prints it ("Local" without TZ).
    def location_name : String
      location.name
    end

    protected def self.presence(v : String?) : String?
      v.try(&.strip).presence
    end

    protected def self.wrap(name : String, &)
      yield
    rescue ex
      raise Error.new("#{name}: #{ex.message}")
    end

    # filepath.Join + Clean for the two-element case used here.
    protected def self.clean_join(dir : String, name : String) : String
      Path.new(dir, name).normalize.to_s
    end

    # Go durations as used in tests: a number with unit ns, us, ms, s, m, h
    # (also combined, e.g. "1m30s").
    def self.parse_duration(s : String) : Time::Span
      raise ArgumentError.new("time: invalid duration #{s.inspect}") unless s.matches?(/\A(\d+(\.\d+)?(ns|us|µs|ms|s|m|h))+\z/)
      total = Time::Span.zero
      s.scan(/(\d+(?:\.\d+)?)(ns|us|µs|ms|s|m|h)/) do |m|
        n = m[1].to_f
        total += case m[2]
                 when "ns"       then n.nanoseconds
                 when "us", "µs" then (n * 1000).nanoseconds
                 when "ms"       then n.milliseconds
                 when "s"        then n.seconds
                 when "m"        then n.minutes
                 else                 n.hours
                 end
      end
      total
    end

    # An IP network (CIDR) like Go's netip.Prefix, always masked.
    struct Prefix
      getter bytes : Bytes
      getter bits : Int32

      def initialize(@bytes, @bits)
      end

      # Parses a comma- or whitespace-separated list of CIDRs or single IP
      # addresses (which become /32 or /128).
      def self.parse_list(s : String) : Array(Prefix)
        s.split(/[, \t\n]/, remove_empty: true).map { |f| parse(f) }
      end

      def self.parse(s : String) : Prefix
        if s.includes?('/')
          addr, _, len = s.partition('/')
          bytes = Prefix.addr_bytes(addr) || raise ArgumentError.new("netip.ParsePrefix(#{s.inspect}): ParseAddr(#{addr.inspect}): unable to parse IP")
          n = len.to_i? if len.matches?(/\A\d+\z/)
          raise ArgumentError.new("netip.ParsePrefix(#{s.inspect}): bad bits after slash: #{len.inspect}") unless n
          raise ArgumentError.new("netip.ParsePrefix(#{s.inspect}): prefix length out of range") if n > bytes.size * 8
          new(mask(bytes, n), n)
        else
          bytes = Prefix.addr_bytes(s) || raise ArgumentError.new("ParseAddr(#{s.inspect}): unable to parse IP")
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

      # The 4 or 16 bytes of an IP address, nil if it is none.
      def self.addr_bytes(s : String) : Bytes?
        return nil if s.includes?('%') # zones are not supported (like netip prefixes)
        if s.matches?(/\A\d{1,3}(\.\d{1,3}){3}\z/)
          return nil if s.split('.').any? { |p| p.size > 1 && p.starts_with?('0') } # Go rejects leading zeros
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

    # Whether addr lies in one of the prefixes (IPv4-mapped IPv6 is unmapped).
    def self.contains_addr?(prefixes : Array(Prefix), addr : String) : Bool
      prefixes.any?(&.contains?(addr))
    end
  end
end
