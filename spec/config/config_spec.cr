require "../spec_helper"

describe Config do
  it "has defaults" do
    c = Config.from_env({} of String => String)
    c.addr.should eq ":8080"
    c.db_path.should eq "./data/zipfelkasse.db"
    c.backup_dir.should eq "data/backups"
    c.mcp_secret.should eq ""
    c.mcp_allowed_cidrs.map(&.to_s).should eq ["160.79.104.0/21"]
    c.trusted_proxies.should be_empty
    c.now.should be_close(Time.utc, 5.seconds)
  end

  it "calls the time zone Local without TZ" do
    Config.from_env({} of String => String).location_name.should eq "Local"
    Config.from_env({"TZ" => ""}).location_name.should eq "Local"
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
    c.location_name.should eq "Europe/Berlin"
    c.mcp_allowed_cidrs.any?(&.contains?("10.1.2.3")).should be_true
    c.mcp_allowed_cidrs.any?(&.contains?("::ffff:192.168.1.5")).should be_true
    c.mcp_allowed_cidrs.any?(&.contains?("192.168.1.6")).should be_false
    c.trusted_proxies.any?(&.contains?("172.18.0.2")).should be_true
    c.trusted_proxies.any?(&.contains?("fd00::1")).should be_true
  end

  it "rejects broken values" do
    [{"MCP_ALLOWED_CIDRS" => "not-a-cidr"}, {"TRUSTED_PROXIES" => "1.2.3.4/99"}, {"TZ" => "Mars/Olympus"}].each do |env|
      expect_raises(Config::Error) { Config.from_env(env) }
    end
  end

  it "names the offending value of a broken CIDR" do
    ex = expect_raises(Config::Error) { Config.from_env({"MCP_ALLOWED_CIDRS" => "10.0.0.0/33"}) }
    ex.message.should eq "invalid MCP_ALLOWED_CIDRS"
    ex.cause.should_not be_nil
  end

  it "reads the test variables" do
    c = Config.new
    c.read_test_hooks({
      "ZIPFELKASSE_TEST_NOW"           => "2026-10-03T10:00:00Z",
      "ZIPFELKASSE_TEST_ECB_URL"       => "http://127.0.0.1:9/ecb/",
      "ZIPFELKASSE_TEST_YNAB_URL"      => "http://127.0.0.1:9/v1",
      "ZIPFELKASSE_TEST_YNAB_DELAY_MS" => "200",
    })
    c.location = Time::Location.load("Europe/Berlin")
    c.now.should eq Time.utc(2026, 10, 3, 10, 0, 0)
    c.today.should eq Time.utc(2026, 10, 3)
    c.ecb_base_url.should eq "http://127.0.0.1:9/ecb/"
    c.ynab_base_url.should eq "http://127.0.0.1:9/v1"
    c.ynab_delay.should eq 200.milliseconds
  end

  it "rejects broken test variables" do
    [{"ZIPFELKASSE_TEST_NOW" => "yesterday"}, {"ZIPFELKASSE_TEST_YNAB_DELAY_MS" => "short"}].each do |env|
      expect_raises(Config::Error) { Config.new.read_test_hooks(env) }
    end
  end

  it "reads the test variables from the environment only when compiled with -Dtest_hooks" do
    c = Config.from_env({"ZIPFELKASSE_TEST_YNAB_URL" => "http://127.0.0.1:9/v1"})
    c.ynab_base_url.should eq(Config::TEST_HOOKS ? "http://127.0.0.1:9/v1" : "")
  end

  it "masks and prints prefixes" do
    Config::Prefix.parse("10.1.2.3/8").to_s.should eq "10.0.0.0/8"
    Config::Prefix.parse("fd00::1/8").to_s.should eq "fd00::/8"
    Config::Prefix.parse("::ffff:1.2.3.4").to_s.should eq "1.2.3.4/32"
    Config::Prefix.parse("2001:db8::1").to_s.should eq "2001:db8::1/128"
  end
end
