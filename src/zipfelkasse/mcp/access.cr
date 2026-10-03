module Zipfelkasse::MCP
  # Forwarding headers count only from a trusted proxy. X-Forwarded-For is read from the right: the first hop that is
  # not a trusted proxy is the client, anything left of it may be forged. An unparsable hop yields nil (fail closed).
  def self.client_ip(remote : Socket::Address?, headers : HTTP::Headers, trusted : Array(Config::Prefix)) : Config::Prefix?
    peer = remote.as?(Socket::IPAddress).try { |address| Config::Prefix.parse_address?(address.address) } || return
    return peer unless trusted.any?(&.contains?(peer))
    hops = headers.get?("X-Forwarded-For").try(&.flat_map(&.split(',')).map(&.strip).reject(&.empty?)) || [] of String
    if hops.empty?
      real = headers["X-Real-IP"]?.try(&.strip).presence
      return real ? Config::Prefix.parse_address?(real) : peer
    end
    client = peer
    hops.reverse_each do |hop|
      client = Config::Prefix.parse_address?(hop) || return
      return client unless trusted.any?(&.contains?(client))
    end
    client
  end
end
