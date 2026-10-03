require "../spec_helper"

describe "MCP.client_ip" do
  trusted = Zipfelkasse::Config::Prefix.parse_list("10.0.0.0/8, 172.16.0.5")
  [
    {"direct", "1.2.3.4:5000", [] of String, "", "1.2.3.4"},
    {"direct IPv6", "[2001:db8::1]:5000", [] of String, "", "2001:db8::1"},
    {"direct without port", "1.2.3.4", [] of String, "", "1.2.3.4"},
    {"XFF spoofing without proxy ignored", "1.2.3.4:5000", ["160.79.104.1"], "", "1.2.3.4"},
    {"X-Real-IP spoofing without proxy ignored", "1.2.3.4:5000", [] of String, "160.79.104.1", "1.2.3.4"},
    {"proxy with XFF", "10.0.0.2:5000", ["160.79.104.1"], "", "160.79.104.1"},
    {"proxy: address prepended by the client does not count", "10.0.0.2:5000", ["160.79.104.1, 6.6.6.6"], "", "6.6.6.6"},
    {"proxy chain", "10.0.0.2:5000", ["6.6.6.6, 160.79.104.1, 172.16.0.5"], "", "160.79.104.1"},
    {"multiple XFF headers", "10.0.0.2:5000", ["6.6.6.6", "160.79.104.1"], "", "160.79.104.1"},
    {"XFF with port", "10.0.0.2:5000", ["160.79.104.1:443"], "", "160.79.104.1"},
    {"XFF IPv6 in brackets", "10.0.0.2:5000", ["[2001:db8::7]:443"], "", "2001:db8::7"},
    {"XFF unparsable is invalid", "10.0.0.2:5000", ["garbage"], "", ""},
    {"XFF partly unparsable is invalid", "10.0.0.2:5000", ["160.79.104.1, garbage"], "", ""},
    {"XFF beats X-Real-IP", "10.0.0.2:5000", ["6.6.6.6"], "160.79.104.1", "6.6.6.6"},
    {"only X-Real-IP", "10.0.0.2:5000", [] of String, "160.79.104.9", "160.79.104.9"},
    {"X-Real-IP unparsable", "10.0.0.2:5000", [] of String, "garbage", ""},
    {"proxy without header", "10.0.0.2:5000", [] of String, "", "10.0.0.2"},
    {"only trusted hops", "10.0.0.2:5000", ["10.0.0.3, 10.0.0.4"], "", "10.0.0.3"},
    {"IPv4-mapped proxy", "[::ffff:10.0.0.2]:5000", ["::ffff:160.79.104.1"], "", "160.79.104.1"},
    {"RemoteAddr unparsable", "@", [] of String, "", ""},
  ].each do |name, remote, xff, real, want|
    it name do
      h = HTTP::Headers.new
      xff.each { |v| h.add("X-Forwarded-For", v) }
      h["X-Real-IP"] = real unless real.empty?
      ip = MCP.client_ip(remote, h, trusted)
      if want.empty?
        ip.valid?.should be_false
      else
        ip.to_s.should eq want
      end
    end
  end
end
