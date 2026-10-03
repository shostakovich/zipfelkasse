require "../spec_helper"

describe MCP do
  it "formats euros with a dot and without grouping" do
    MCP.eur(-300000).should eq "-3000.00"
  end

  it "formats an amount in its currency" do
    MCP.money(2340, "usd").should eq "23.40 USD"
    MCP.money(1500, "JPY").should eq "1500 JPY"
  end

  describe ".parse_decimal" do
    {
      {"23.4", 2} => 2340, {"23.40", 2} => 2340, {"23", 2} => 2300, {"1.000", 2} => 100, {"0.5", 2} => 50,
      {" 7 ", 2} => 700, {"5.", 2} => 500, {"1200.00", 0} => 1200,
    }.each do |(text, decimals), minor|
      it "reads #{text.inspect} with #{decimals} decimals as #{minor}" do
        MCP.parse_decimal(text, decimals).should eq minor
      end
    end

    ["1.234", "1,5", "1.000,00", "-1", "+1", ".5", "1e3", "", "1.2.3", "1 000"].each do |text|
      it "rejects #{text.inspect}" do
        expect_raises(MCP::DecimalError) { MCP.parse_decimal(text, 2) }
      end
    end
  end
end
