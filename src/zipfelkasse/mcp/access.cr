require "socket"

module Zipfelkasse::MCP
  # An IP address (IPv4-mapped IPv6 unmapped, zone dropped); nil bytes =
  # invalid.
  struct Addr
    getter bytes : Bytes?

    def initialize(@bytes = nil)
    end

    def valid? : Bool
      !@bytes.nil?
    end

    def in?(prefixes : Array(Config::Prefix)) : Bool
      b = @bytes || return false
      prefixes.any?(&.contains?(b))
    end

    def to_s(io : IO) : Nil
      b = @bytes
      if b.nil?
        io << "invalid IP"
      elsif b.size == 4
        io << b.join('.')
      else
        fields = StaticArray(UInt16, 8).new { |i| (b[2 * i].to_u16 << 8) | b[2 * i + 1] }
        io << Socket::IPAddress.v6(fields, port: 0_u16).address
      end
    end

    # "1.2.3.4", "1.2.3.4:567", "::1", "[::1]:567"; anything else is invalid.
    def self.parse(s : String) : Addr
      s = s.strip
      if b = addr_bytes(s)
        return new(b)
      end
      host = split_host(s) || return new
      new(addr_bytes(host))
    end

    private def self.addr_bytes(s : String) : Bytes?
      s = s.partition('%')[0] if s.includes?(':')
      Config::Prefix.addr_bytes(s).try { |b| Config::Prefix.unmap(b) }
    end

    # The host of "host:port"; nil without a port separator.
    private def self.split_host(s : String) : String?
      i = s.rindex(':') || return
      host = s[0, i]
      if host.starts_with?('[')
        return unless host.ends_with?(']')
        host = host[1...-1]
      elsif host.includes?(':')
        return
      end
      host unless host.includes?('[') || host.includes?(']')
    end
  end

  # The client's address. Headers only count when the connection comes from
  # a trusted proxy (anyone could forge them otherwise): then X-Forwarded-For
  # is read from the right, and the first hop that is not itself a trusted
  # proxy is the client (anything left of it may come from the client).
  # Without X-Forwarded-For, X-Real-IP applies; without both, the proxy
  # itself. An unparsable hop makes the result invalid (fail closed).
  def self.client_ip(remote_addr : String, headers : HTTP::Headers, trusted : Array(Config::Prefix)) : Addr
    remote = Addr.parse(remote_addr)
    return remote unless remote.in?(trusted)
    hops = headers.get?("X-Forwarded-For").try(&.flat_map(&.split(',')).map(&.strip).reject(&.empty?)) || [] of String
    if hops.empty?
      real = MCP.header(headers, "X-Real-IP").strip
      return real.empty? ? remote : Addr.parse(real)
    end
    hops.reverse_each do |hop|
      a = Addr.parse(hop)
      return a unless a.valid? && a.in?(trusted)
    end
    Addr.parse(hops.first)
  end
end
