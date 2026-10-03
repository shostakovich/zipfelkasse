require "../spec_helper"

alias Config = Zipfelkasse::Config

describe Zipfelkasse::Config do
  it "has defaults" do
    c = Config.from_env({} of String => String)
    c.addr.should eq ":8080"
    c.db_path.should eq "./data/zipfelkasse.db"
    c.backup_dir.should eq "data/backups"
    c.mcp_secret.should eq ""
    c.mcp_allowed_cidrs.map(&.to_s).should eq ["160.79.104.0/21"]
    c.trusted_proxies.should be_empty
    c.frozen_now.should be_nil
  end

  it "reads all variables" do
    c = Config.from_env({
      "ZIPFELKASSE_ADDR"  => "127.0.0.1:9000",
      "ZIPFELKASSE_DB"    => "/data/zipfelkasse.db",
      "MCP_SECRET"        => " secret ",
      "MCP_ALLOWED_CIDRS" => "10.0.0.0/8, 192.168.1.5",
      "TRUSTED_PROXIES"   => "172.18.0.2 fd00::/8",
      "TZ"                => "Europe/Berlin",
    })
    c.backup_dir.should eq "/data/backups"
    c.mcp_secret.should eq "secret"
    c.location.name.should eq "Europe/Berlin"
    Config.contains_addr?(c.mcp_allowed_cidrs, "10.1.2.3").should be_true
    Config.contains_addr?(c.mcp_allowed_cidrs, "::ffff:192.168.1.5").should be_true
    Config.contains_addr?(c.mcp_allowed_cidrs, "192.168.1.6").should be_false
    Config.contains_addr?(c.trusted_proxies, "172.18.0.2").should be_true
    Config.contains_addr?(c.trusted_proxies, "fd00::1").should be_true
  end

  it "rejects broken values" do
    [{"MCP_ALLOWED_CIDRS" => "not-a-cidr"}, {"TRUSTED_PROXIES" => "1.2.3.4/99"}, {"TZ" => "Mars/Olympus"},
     {"ZIPFELKASSE_TEST_NOW" => "gestern"}, {"ZIPFELKASSE_TEST_YNAB_DELAY" => "kurz"}].each do |env|
      expect_raises(Config::Error) { Config.from_env(env) }
    end
  end

  it "reads the test overrides" do
    c = Config.from_env({
      "ZIPFELKASSE_TEST_NOW"        => "2026-10-03T10:00:00Z",
      "ZIPFELKASSE_TEST_ECB_URL"    => "http://127.0.0.1:9/ecb/",
      "ZIPFELKASSE_TEST_YNAB_URL"   => "http://127.0.0.1:9/v1",
      "ZIPFELKASSE_TEST_YNAB_DELAY" => "200ms",
      "TZ"                          => "Europe/Berlin",
    })
    c.now.should eq Time.utc(2026, 10, 3, 10, 0, 0)
    c.today.should eq Time.utc(2026, 10, 3)
    c.ecb_base_url.should eq "http://127.0.0.1:9/ecb/"
    c.ynab_base_url.should eq "http://127.0.0.1:9/v1"
    c.ynab_delay.should eq 200.milliseconds
  end

  it "masks and prints prefixes" do
    Config::Prefix.parse("10.1.2.3/8").to_s.should eq "10.0.0.0/8"
    Config::Prefix.parse("fd00::1/8").to_s.should eq "fd00::/8"
    Config::Prefix.parse("::ffff:1.2.3.4").to_s.should eq "1.2.3.4/32"
    Config::Prefix.parse("2001:db8::1").to_s.should eq "2001:db8::1/128"
  end
end
