require "../spec_helper"

describe "MCP.client_ip" do
  trusted = Config::Prefix.parse_list("10.0.0.0/8, 172.16.0.5")
  [
    {"direct", "1.2.3.4", [] of String, "", "1.2.3.4"},
    {"direct IPv6", "2001:db8::1", [] of String, "", "2001:db8::1"},
    {"XFF spoofing without proxy ignored", "1.2.3.4", ["160.79.104.1"], "", "1.2.3.4"},
    {"X-Real-IP spoofing without proxy ignored", "1.2.3.4", [] of String, "160.79.104.1", "1.2.3.4"},
    {"proxy with XFF", "10.0.0.2", ["160.79.104.1"], "", "160.79.104.1"},
    {"proxy: address prepended by the client does not count", "10.0.0.2", ["160.79.104.1, 6.6.6.6"], "", "6.6.6.6"},
    {"proxy chain", "10.0.0.2", ["6.6.6.6, 160.79.104.1, 172.16.0.5"], "", "160.79.104.1"},
    {"multiple XFF headers", "10.0.0.2", ["6.6.6.6", "160.79.104.1"], "", "160.79.104.1"},
    {"XFF with port is invalid", "10.0.0.2", ["160.79.104.1:443"], "", nil},
    {"XFF unparsable is invalid", "10.0.0.2", ["garbage"], "", nil},
    {"XFF partly unparsable is invalid", "10.0.0.2", ["160.79.104.1, garbage"], "", nil},
    {"XFF beats X-Real-IP", "10.0.0.2", ["6.6.6.6"], "160.79.104.1", "6.6.6.6"},
    {"only X-Real-IP", "10.0.0.2", [] of String, "160.79.104.9", "160.79.104.9"},
    {"X-Real-IP unparsable", "10.0.0.2", [] of String, "garbage", nil},
    {"proxy without header", "10.0.0.2", [] of String, "", "10.0.0.2"},
    {"only trusted hops", "10.0.0.2", ["10.0.0.3, 10.0.0.4"], "", "10.0.0.3"},
    {"IPv4-mapped proxy and hop", "::ffff:10.0.0.2", ["::ffff:160.79.104.1"], "", "160.79.104.1"},
  ].each do |name, remote, xff, real, want|
    it name do
      h = HTTP::Headers.new
      xff.each { |v| h.add("X-Forwarded-For", v) }
      h["X-Real-IP"] = real unless real.empty?
      MCP.client_ip(Socket::IPAddress.new(remote, 5000), h, trusted).try(&.to_s).should eq want
    end
  end

  it "has no address for a connection without an IP address" do
    MCP.client_ip(nil, HTTP::Headers.new, trusted).should be_nil
  end
end

describe Config::Prefix do
  it "masks and prints prefixes" do
    Config::Prefix.parse("10.1.2.3/8").to_s.should eq "10.0.0.0/8"
    Config::Prefix.parse("fd00::1/8").to_s.should eq "fd00::/8"
    Config::Prefix.parse("::ffff:1.2.3.4").to_s.should eq "1.2.3.4"
    Config::Prefix.parse("2001:db8::1").to_s.should eq "2001:db8::1"
  end

  it "treats IPv4 and IPv4-mapped IPv6 alike" do
    Config::Prefix.parse("192.168.0.0/16").contains?(Config::Prefix.parse("::ffff:192.168.1.5")).should be_true
    Config::Prefix.parse("::/0").contains?(Config::Prefix.parse("1.2.3.4")).should be_true
  end

  it "reads the length of an IPv4-mapped network in IPv6 bits" do
    Config::Prefix.parse("::ffff:192.168.0.0/112").should eq Config::Prefix.parse("192.168.0.0/16")
    Config::Prefix.parse("::ffff:192.168.0.0/112").to_s.should eq "192.168.0.0/16"
  end

  {"010.1.2.3", "1.2.3.4/33", "fd00::/129", "::ffff:1.2.3.4/129", "1.2.3", "10.0.0.0/x"}.each do |text|
    it "refuses #{text.inspect}" do
      expect_raises(ArgumentError) { Config::Prefix.parse(text) }
    end
  end
end
