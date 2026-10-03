require "../spec_helper"

private def parts(*pairs : {Int32, Int64 | Int32}) : Array(Domain::Part)
  pairs.map { |(id, weight)| Domain::Part.new(id.to_i64, weight.to_i64) }.to_a
end

private def amounts(shares : Array(Domain::Share)) : Hash(Int64, Int64)
  shares.to_h { |s| {s.participant_id, s.amount_cents} }
end

describe Domain do
  describe ".split" do
    {
      {"equal even", Domain::SplitMode::Equal, 900, parts({1, 1}, {2, 1}, {3, 1}), {1 => 300, 2 => 300, 3 => 300}},
      {"equal remainder to smallest ID", Domain::SplitMode::Equal, 1000, parts({3, 1}, {1, 1}, {2, 1}), {1 => 334, 2 => 333, 3 => 333}},
      {"equal two cents remainder", Domain::SplitMode::Equal, 1001, parts({1, 0}, {2, 0}, {3, 0}), {1 => 334, 2 => 334, 3 => 333}},
      {"equal one person", Domain::SplitMode::Equal, 1234, parts({7, 1}), {7 => 1234}},
      {"equal 1 cent among 3", Domain::SplitMode::Equal, 1, parts({1, 1}, {2, 1}, {3, 1}), {1 => 1, 2 => 0, 3 => 0}},
      {"shares 2:1", Domain::SplitMode::Shares, 900, parts({1, 2}, {2, 1}), {1 => 600, 2 => 300}},
      {"shares largest remainder", Domain::SplitMode::Shares, 1000, parts({1, 1}, {2, 2}), {1 => 333, 2 => 667}},
      {"shares with zero", Domain::SplitMode::Shares, 1000, parts({1, 1}, {2, 0}), {1 => 1000, 2 => 0}},
      {"percent", Domain::SplitMode::Percent, 1000, parts({1, 3333}, {2, 3333}, {3, 3334}), {1 => 333, 2 => 333, 3 => 334}},
      {"percent remainder by largest remainder", Domain::SplitMode::Percent, 101, parts({1, 5000}, {2, 5000}), {1 => 51, 2 => 50}},
      {"percent 70/30", Domain::SplitMode::Percent, 1999, parts({1, 7000}, {2, 3000}), {1 => 1399, 2 => 600}},
      {"amounts", Domain::SplitMode::Amount, 1000, parts({1, 250}, {2, 750}), {1 => 250, 2 => 750}},
    }.each do |(name, mode, total, ps, want)|
      it name do
        got = Domain.split(mode, total.to_i64, ps, 0)
        amounts(got).should eq want.to_h { |id, cents| {id.to_i64, cents.to_i64} }
        got.sum(&.amount_cents).should eq total
        got.map(&.participant_id).should eq got.map(&.participant_id).sort.uniq
      end
    end
  end

  describe ".split rotating ties" do
    three = parts({3, 1}, {1, 1}, {2, 1})
    {
      {"two people, even ID", Domain::SplitMode::Equal, 1001, parts({1, 1}, {2, 1}), 10, {1 => 501, 2 => 500}},
      {"two people, odd ID", Domain::SplitMode::Equal, 1001, parts({1, 1}, {2, 1}), 11, {1 => 500, 2 => 501}},
      {"three, start 0", Domain::SplitMode::Equal, 1000, three, 0, {1 => 334, 2 => 333, 3 => 333}},
      {"three, start 1", Domain::SplitMode::Equal, 1000, three, 1, {1 => 333, 2 => 334, 3 => 333}},
      {"three, start 2", Domain::SplitMode::Equal, 1000, three, 2, {1 => 333, 2 => 333, 3 => 334}},
      {"three, start 3 = 0", Domain::SplitMode::Equal, 1000, three, 3, {1 => 334, 2 => 333, 3 => 333}},
      {"two cents, start 1", Domain::SplitMode::Equal, 1001, three, 1, {1 => 333, 2 => 334, 3 => 334}},
      {"two cents, start 2 (round-robin)", Domain::SplitMode::Equal, 1001, three, 2, {1 => 334, 2 => 333, 3 => 334}},
      {"negative start value", Domain::SplitMode::Equal, 1000, three, -1, {1 => 333, 2 => 333, 3 => 334}},
      {"largest remainder takes precedence", Domain::SplitMode::Shares, 5, parts({1, 2}, {2, 1}, {3, 1}), 1, {1 => 3, 2 => 1, 3 => 1}},
      {"only the tied rotate, start 0", Domain::SplitMode::Shares, 6, parts({1, 2}, {2, 1}, {3, 1}), 0, {1 => 3, 2 => 2, 3 => 1}},
      {"only the tied rotate, start 1", Domain::SplitMode::Shares, 6, parts({1, 2}, {2, 1}, {3, 1}), 1, {1 => 3, 2 => 1, 3 => 2}},
      {"percent 50/50", Domain::SplitMode::Percent, 101, parts({1, 5000}, {2, 5000}), 7, {1 => 50, 2 => 51}},
      {"amounts unaffected", Domain::SplitMode::Amount, 1000, parts({1, 250}, {2, 750}), 1, {1 => 250, 2 => 750}},
    }.each do |(name, mode, total, ps, rotation, want)|
      it name do
        amounts(Domain.split(mode, total.to_i64, ps, rotation.to_i64)).should eq want.to_h { |id, cents| {id.to_i64, cents.to_i64} }
      end
    end
  end

  it "stores weight 1 for equal splits" do
    Domain.split(Domain::SplitMode::Equal, 100, parts({1, 0}, {2, 5}), 0).map(&.weight).should eq [1, 1]
  end

  describe ".split errors" do
    {
      {"no people", Domain::SplitMode::Equal, 100_i64, [] of Domain::Part, "Mindestens eine Person"},
      {"amount zero", Domain::SplitMode::Equal, 0_i64, parts({1, 1}), "größer als 0"},
      {"amount negative", Domain::SplitMode::Equal, -5_i64, parts({1, 1}), "größer als 0"},
      {"amount too large", Domain::SplitMode::Equal, Domain::MAX_AMOUNT_CENTS + 1, parts({1, 1}), "zu groß"},
      {"duplicate", Domain::SplitMode::Equal, 100_i64, parts({1, 1}, {1, 1}), "doppelt"},
      {"invalid ID", Domain::SplitMode::Equal, 100_i64, parts({0, 1}), "Ungültige Person"},
      {"negative shares", Domain::SplitMode::Shares, 100_i64, parts({1, -1}, {2, 2}), "negativ"},
      {"shares sum zero", Domain::SplitMode::Shares, 100_i64, parts({1, 0}), "größer als 0"},
      {"percent not 100", Domain::SplitMode::Percent, 100_i64, parts({1, 5000}, {2, 4000}), "100 %"},
      {"amounts sum wrong", Domain::SplitMode::Amount, 1000_i64, parts({1, 500}, {2, 400}), "10,00 €"},
    }.each do |(name, mode, total, ps, message)|
      it name do
        expect_raises(Domain::ValidationError, message) { Domain.split(mode, total, ps, 0) }
      end
    end

    it "explains why a split is refused" do
      expect_invalid("Anteile dürfen höchstens 1000000 sein.") { Domain.split(Domain::SplitMode::Shares, 100, parts({1, 1_000_001}), 0) }
      expect_invalid("Die Prozente müssen zusammen 100 % ergeben.") { Domain.split(Domain::SplitMode::Percent, 100, parts({1, 10001}), 0) }
      expect_invalid("Die Prozente müssen zusammen 100 % ergeben (aktuell 90,00 %).") { Domain.split(Domain::SplitMode::Percent, 100, parts({1, 5000}, {2, 4000}), 0) }
      expect_invalid("Die Beträge müssen zusammen 1.000 JPY ergeben (aktuell 1 JPY).") { Domain.split_converted(Domain::SplitMode::Amount, 909, 1000, "jpy", parts({1, 1}), 0) }
    end
  end

  describe ".allocate" do
    max = Domain::MAX_AMOUNT_CENTS

    {
      "gives the larger remainder the cent"                            => {667_i64, [600_i64, 400_i64], 0_i64, [400_i64, 267_i64]},
      "gives the extra cent to the first of three equal weights"       => {100_i64, [1_i64, 1_i64, 1_i64], 0_i64, [34_i64, 33_i64, 33_i64]},
      "rotates the extra cent with the rotation"                       => {100_i64, [1_i64, 1_i64, 1_i64], 4_i64, [33_i64, 34_i64, 33_i64]},
      "gives two extra cents to the tied entries from the rotation on" => {200_i64, [1_i64, 1_i64, 1_i64], 1_i64, [66_i64, 67_i64, 67_i64]},
      "wraps a negative rotation around"                               => {100_i64, [1_i64, 1_i64, 1_i64], -1_i64, [33_i64, 33_i64, 34_i64]},
      "gives nothing to a weight of 0"                                 => {100_i64, [2_i64, 1_i64, 1_i64, 0_i64], 1_i64, [50_i64, 25_i64, 25_i64, 0_i64]},
      "distributes the total in proportion to weights of any sum"      => {909_i64, [333_i64, 333_i64, 334_i64], 0_i64, [303_i64, 303_i64, 303_i64]},
      "does not rotate when nothing is left over"                      => {1000_i64, [250_i64, 750_i64], 3_i64, [250_i64, 750_i64]},
      "gives nothing when all weights are 0"                           => {5_i64, [0_i64, 0_i64], 0_i64, [0_i64, 0_i64]},
      "gives nothing when the total is 0"                              => {0_i64, [1_i64, 2_i64], 5_i64, [0_i64, 0_i64]},
      "does not overflow when total times weight exceeds Int64::MAX"   => {max, [999_999_999_999_999_i64, 1_i64], 0_i64, [max, 0_i64]},
      "does not overflow for weights beyond the maximum amount"        => {max, [max * 100, max * 100], 1_i64, [max // 2, max // 2]},
      "rotates through eight tied entries"                             => {7_i64, [1_i64] * 8, 5_i64, [1_i64, 1_i64, 1_i64, 1_i64, 0_i64, 1_i64, 1_i64, 1_i64]},
      "rotates only the tied entries"                                  => {10_i64, [3_i64, 3_i64, 1_i64, 1_i64, 1_i64, 1_i64], -7_i64, [3_i64, 3_i64, 1_i64, 1_i64, 1_i64, 1_i64]},
    }.each do |name, (total, weights, rotation, allocated)|
      it name do
        Domain.allocate(total, weights, rotation).should eq allocated
      end
    end
  end

  describe ".split_converted" do
    people = parts({3, 334}, {1, 333}, {2, 333})

    it "splits the converted euro amount in proportion to the weights in the foreign currency" do
      Domain.split_converted(Domain::SplitMode::Amount, 909, 1000, "USD", people, 0).should eq [
        Domain::Share.new(1, 333, 303), Domain::Share.new(2, 333, 303), Domain::Share.new(3, 334, 303),
      ]
    end

    it "rotates a tied cent with the expense ID" do
      shares = amounts(Domain.split_converted(Domain::SplitMode::Amount, 1001, 1000, "USD", parts({1, 500}, {2, 500}), 1))

      {shares[1], shares[2]}.should eq({500, 501})
    end

    it "splits like .split in the other modes" do
      shares = amounts(Domain.split_converted(Domain::SplitMode::Equal, 1000, 1100, "USD", people, 1))

      {shares[1], shares[2], shares[3]}.should eq({333, 334, 333})
    end

    {
      "weights that fall short of the amount" => {parts({1, 600}, {2, 300}), "Die Beträge müssen zusammen 10,00 USD ergeben (aktuell 9,00 USD)."},
      "a single weight that falls short"      => {parts({1, 909}), "Die Beträge müssen zusammen 10,00 USD ergeben (aktuell 9,09 USD)."},
      "a negative weight"                     => {parts({1, -1}, {2, 1001}), "negativ"},
      "weights whose sum overflows"           => {parts({1, 1_i64 << 62}, {2, 1_i64 << 62}, {3, 1_i64 << 62}), "zu groß"},
    }.each do |name, (weights, message)|
      it "refuses #{name}" do
        expect_raises(Domain::ValidationError, message) { Domain.split_converted(Domain::SplitMode::Amount, 909, 1000, "USD", weights, 0) }
      end
    end
  end

  it "names the split modes by their stored keys" do
    Domain::SplitMode.values.map(&.key).should eq %w(equal shares percent amount)
    Domain::SplitMode.from_key?("shares").should eq Domain::SplitMode::Shares
    Domain::SplitMode.from_key?("Shares").should be_nil
    Domain::SplitMode.from_key?("foo").should be_nil
  end

  describe ".parse_weight" do
    {"5" => 5, " 5 " => 5, "+5" => 5, "-3" => -3, "\t5" => 5}.each do |text, shares|
      it "reads #{text.inspect} as #{shares} shares" do
        Domain.parse_weight(Domain::SplitMode::Shares, "EUR", text).should eq shares
      end
    end

    {"1.5", "", "x"}.each do |text|
      it "refuses #{text.inspect} as shares" do
        expect_invalid("Anteile müssen ganze Zahlen sein („#{text}“).") { Domain.parse_weight(Domain::SplitMode::Shares, "EUR", text) }
      end
    end

    it "reads amounts in the minor unit of the currency and percentages in basis points" do
      Domain.parse_weight(Domain::SplitMode::Amount, "JPY", "1.500").should eq 1500
      Domain.parse_weight(Domain::SplitMode::Percent, "JPY", "33,3").should eq 3330
    end

    it "ignores the text of an equal split" do
      Domain.parse_weight(Domain::SplitMode::Equal, "JPY", "xyz").should eq 0
    end
  end

  describe ".weight_decimals" do
    it "is the decimals of the currency for amounts, 2 for percentages and 0 for shares" do
      Domain.weight_decimals(Domain::SplitMode::Amount, "KWD").should eq 3
      Domain.weight_decimals(Domain::SplitMode::Percent, "KWD").should eq 2
      Domain.weight_decimals(Domain::SplitMode::Shares, "KWD").should eq 0
    end
  end

  it "reads and writes parts and shares as JSON, the format of stored recurring templates" do
    Domain::Part.new(1, 2).to_json.should eq %({"participant_id":1,"weight":2})
    Domain::Share.from_json(%({"participant_id":3,"weight":1,"amount_cents":250})).should eq Domain::Share.new(3, 1, 250)
  end
end
