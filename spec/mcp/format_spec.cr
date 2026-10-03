require "../spec_helper"

describe MCP do
  it "formats euros with a dot and without grouping" do
    MCP.eur(-300000).should eq "-3000.00"
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

    [{"1.234", 2}, {"1.5", 0}, {"1,5", 2}, {"1.000,00", 2}, {"-1", 2}, {"+1", 2}, {".5", 2}, {"1e3", 2}, {"", 2},
     {"1.2.3", 2}, {"1 000", 2}, {"1234567890123456", 2}].each do |text, decimals|
      it "rejects #{text.inspect} with #{decimals} decimals" do
        MCP.parse_decimal(text, decimals).should be_nil
      end
    end
  end
end
