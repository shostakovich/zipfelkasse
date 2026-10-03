require "../spec_helper"

private alias D = Zipfelkasse::Domain

private def parts(*pairs : {Int32, Int64 | Int32}) : Array(D::Part)
  pairs.map { |(id, weight)| D::Part.new(id.to_i64, weight.to_i64) }.to_a
end

private def amounts(shares : Array(D::Share)) : Hash(Int64, Int64)
  shares.to_h { |s| {s.participant_id, s.amount_cents} }
end

private def validation_error(&) : String
  yield
  fail "expected a ValidationError"
rescue e : Zipfelkasse::Domain::ValidationError
  e.msg
end

describe Zipfelkasse::Domain do
  describe ".split" do
    {
      {"equal even", D::SPLIT_EQUAL, 900, parts({1, 1}, {2, 1}, {3, 1}), {1 => 300, 2 => 300, 3 => 300}},
      {"equal remainder to smallest ID", D::SPLIT_EQUAL, 1000, parts({3, 1}, {1, 1}, {2, 1}), {1 => 334, 2 => 333, 3 => 333}},
      {"equal two cents remainder", D::SPLIT_EQUAL, 1001, parts({1, 0}, {2, 0}, {3, 0}), {1 => 334, 2 => 334, 3 => 333}},
      {"equal one person", D::SPLIT_EQUAL, 1234, parts({7, 1}), {7 => 1234}},
      {"equal 1 cent among 3", D::SPLIT_EQUAL, 1, parts({1, 1}, {2, 1}, {3, 1}), {1 => 1, 2 => 0, 3 => 0}},
      {"shares 2:1", D::SPLIT_SHARES, 900, parts({1, 2}, {2, 1}), {1 => 600, 2 => 300}},
      {"shares largest remainder", D::SPLIT_SHARES, 1000, parts({1, 1}, {2, 2}), {1 => 333, 2 => 667}},
      {"shares with zero", D::SPLIT_SHARES, 1000, parts({1, 1}, {2, 0}), {1 => 1000, 2 => 0}},
      {"percent", D::SPLIT_PERCENT, 1000, parts({1, 3333}, {2, 3333}, {3, 3334}), {1 => 333, 2 => 333, 3 => 334}},
      {"percent remainder by largest remainder", D::SPLIT_PERCENT, 101, parts({1, 5000}, {2, 5000}), {1 => 51, 2 => 50}},
      {"percent 70/30", D::SPLIT_PERCENT, 1999, parts({1, 7000}, {2, 3000}), {1 => 1399, 2 => 600}},
      {"amounts", D::SPLIT_AMOUNT, 1000, parts({1, 250}, {2, 750}), {1 => 250, 2 => 750}},
    }.each do |(name, mode, total, ps, want)|
      it name do
        got = D.split(mode, total.to_i64, ps, 0)
        amounts(got).should eq want.to_h { |id, cents| {id.to_i64, cents.to_i64} }
        got.sum(&.amount_cents).should eq total
        got.map(&.participant_id).should eq got.map(&.participant_id).sort.uniq
      end
    end
  end

  describe ".split rotating ties" do
    three = parts({3, 1}, {1, 1}, {2, 1})
    {
      {"two people, even ID", D::SPLIT_EQUAL, 1001, parts({1, 1}, {2, 1}), 10, {1 => 501, 2 => 500}},
      {"two people, odd ID", D::SPLIT_EQUAL, 1001, parts({1, 1}, {2, 1}), 11, {1 => 500, 2 => 501}},
      {"three, start 0", D::SPLIT_EQUAL, 1000, three, 0, {1 => 334, 2 => 333, 3 => 333}},
      {"three, start 1", D::SPLIT_EQUAL, 1000, three, 1, {1 => 333, 2 => 334, 3 => 333}},
      {"three, start 2", D::SPLIT_EQUAL, 1000, three, 2, {1 => 333, 2 => 333, 3 => 334}},
      {"three, start 3 = 0", D::SPLIT_EQUAL, 1000, three, 3, {1 => 334, 2 => 333, 3 => 333}},
      {"two cents, start 1", D::SPLIT_EQUAL, 1001, three, 1, {1 => 333, 2 => 334, 3 => 334}},
      {"two cents, start 2 (round-robin)", D::SPLIT_EQUAL, 1001, three, 2, {1 => 334, 2 => 333, 3 => 334}},
      {"negative start value", D::SPLIT_EQUAL, 1000, three, -1, {1 => 333, 2 => 333, 3 => 334}},
      {"largest remainder takes precedence", D::SPLIT_SHARES, 5, parts({1, 2}, {2, 1}, {3, 1}), 1, {1 => 3, 2 => 1, 3 => 1}},
      {"only the tied rotate, start 0", D::SPLIT_SHARES, 6, parts({1, 2}, {2, 1}, {3, 1}), 0, {1 => 3, 2 => 2, 3 => 1}},
      {"only the tied rotate, start 1", D::SPLIT_SHARES, 6, parts({1, 2}, {2, 1}, {3, 1}), 1, {1 => 3, 2 => 1, 3 => 2}},
      {"percent 50/50", D::SPLIT_PERCENT, 101, parts({1, 5000}, {2, 5000}), 7, {1 => 50, 2 => 51}},
      {"amounts unaffected", D::SPLIT_AMOUNT, 1000, parts({1, 250}, {2, 750}), 1, {1 => 250, 2 => 750}},
    }.each do |(name, mode, total, ps, rotation, want)|
      it name do
        amounts(D.split(mode, total.to_i64, ps, rotation.to_i64)).should eq want.to_h { |id, cents| {id.to_i64, cents.to_i64} }
      end
    end
  end

  it "stores weight 1 for equal splits" do
    D.split(D::SPLIT_EQUAL, 100, parts({1, 0}, {2, 5}), 0).map(&.weight).should eq [1, 1]
  end

  describe ".split errors" do
    {
      {"no people", D::SPLIT_EQUAL, 100_i64, [] of D::Part, "Mindestens eine Person"},
      {"amount zero", D::SPLIT_EQUAL, 0_i64, parts({1, 1}), "größer als 0"},
      {"amount negative", D::SPLIT_EQUAL, -5_i64, parts({1, 1}), "größer als 0"},
      {"amount too large", D::SPLIT_EQUAL, D::MAX_AMOUNT_CENTS + 1, parts({1, 1}), "zu groß"},
      {"duplicate", D::SPLIT_EQUAL, 100_i64, parts({1, 1}, {1, 1}), "doppelt"},
      {"invalid ID", D::SPLIT_EQUAL, 100_i64, parts({0, 1}), "Ungültige Person"},
      {"unknown mode", D::SplitMode.new("x"), 100_i64, parts({1, 1}), "Aufteilungsart"},
      {"negative shares", D::SPLIT_SHARES, 100_i64, parts({1, -1}, {2, 2}), "negativ"},
      {"shares sum zero", D::SPLIT_SHARES, 100_i64, parts({1, 0}), "größer als 0"},
      {"percent not 100", D::SPLIT_PERCENT, 100_i64, parts({1, 5000}, {2, 4000}), "100 %"},
      {"amounts sum wrong", D::SPLIT_AMOUNT, 1000_i64, parts({1, 500}, {2, 400}), "10,00 €"},
    }.each do |(name, mode, total, ps, message)|
      it name do
        validation_error { D.split(mode, total, ps, 0) }.should contain message
      end
    end

    it "uses the exact messages" do
      validation_error { D.split(D::SPLIT_SHARES, 100, parts({1, 1_000_001}), 0) }.should eq "Anteile dürfen höchstens 1000000 sein."
      validation_error { D.split(D::SPLIT_PERCENT, 100, parts({1, 10001}), 0) }.should eq "Die Prozente müssen zusammen 100 % ergeben."
      validation_error { D.split(D::SPLIT_PERCENT, 100, parts({1, 5000}, {2, 4000}), 0) }.should eq "Die Prozente müssen zusammen 100 % ergeben (aktuell 90,00 %)."
      validation_error { D.split(D::SplitMode.new("x"), 100, parts({1, 1}), 0) }.should eq "Unbekannte Aufteilungsart „x“."
      validation_error { D.split_converted(D::SPLIT_AMOUNT, 909, 1000, "jpy", parts({1, 1}), 0) }.should eq "Die Beträge müssen zusammen 1.000 JPY ergeben (aktuell 1 JPY)."
    end
  end

  it "allocates by largest remainder with rotation" do
    max = D::MAX_AMOUNT_CENTS
    [
      {667_i64, [600_i64, 400_i64], 0_i64, [400_i64, 267_i64]},
      {100_i64, [1_i64, 1_i64, 1_i64], 0_i64, [34_i64, 33_i64, 33_i64]},
      {100_i64, [1_i64, 1_i64, 1_i64], 4_i64, [33_i64, 34_i64, 33_i64]},
      {200_i64, [1_i64, 1_i64, 1_i64], 1_i64, [66_i64, 67_i64, 67_i64]},  # two extra cents from index 1 on
      {100_i64, [1_i64, 1_i64, 1_i64], -1_i64, [33_i64, 33_i64, 34_i64]}, # negative rotation wraps around
      {100_i64, [2_i64, 1_i64, 1_i64, 0_i64], 1_i64, [50_i64, 25_i64, 25_i64, 0_i64]},
      {909_i64, [333_i64, 333_i64, 334_i64], 0_i64, [303_i64, 303_i64, 303_i64]},
      {1000_i64, [250_i64, 750_i64], 3_i64, [250_i64, 750_i64]},
      {5_i64, [0_i64, 0_i64], 0_i64, [0_i64, 0_i64]},
      # No overflow: total · weight > Int64::MAX.
      {max, [999_999_999_999_999_i64, 1_i64], 0_i64, [max, 0_i64]},
      {max, [max * 100, max * 100], 1_i64, [max // 2, max // 2]},
      {0_i64, [1_i64, 2_i64], 5_i64, [0_i64, 0_i64]},
      {7_i64, [1_i64] * 8, 5_i64, [1_i64, 1_i64, 1_i64, 1_i64, 0_i64, 1_i64, 1_i64, 1_i64]},
      {10_i64, [3_i64, 3_i64, 1_i64, 1_i64, 1_i64, 1_i64], -7_i64, [3_i64, 3_i64, 1_i64, 1_i64, 1_i64, 1_i64]},
    ].each do |(total, weights, rotation, want)|
      D.allocate(total, weights, rotation).should eq want
    end
  end

  it "splits foreign amounts" do
    ps = parts({3, 334}, {1, 333}, {2, 333})
    D.split_converted(D::SPLIT_AMOUNT, 909, 1000, "USD", ps, 0).should eq [
      D::Share.new(1, 333, 303), D::Share.new(2, 333, 303), D::Share.new(3, 334, 303),
    ]
    m = amounts(D.split_converted(D::SPLIT_AMOUNT, 1001, 1000, "USD", parts({1, 500}, {2, 500}), 1))
    {m[1], m[2]}.should eq({500, 501}) # tie, rotation 1
    # Other modes as split.
    m = amounts(D.split_converted(D::SPLIT_EQUAL, 1000, 1100, "USD", ps, 1))
    {m[1], m[2], m[3]}.should eq({333, 334, 333})
    {
      parts({1, 600}, {2, 300})                                   => "Die Beträge müssen zusammen 10,00 USD ergeben (aktuell 9,00 USD).",
      parts({1, 909})                                             => "Die Beträge müssen zusammen 10,00 USD ergeben (aktuell 9,09 USD).",
      parts({1, -1}, {2, 1001})                                   => "negativ",
      parts({1, 1_i64 << 62}, {2, 1_i64 << 62}, {3, 1_i64 << 62}) => "zu groß",
    }.each do |ps, message|
      validation_error { D.split_converted(D::SPLIT_AMOUNT, 909, 1000, "USD", ps, 0) }.should contain message
    end
  end

  it "knows the split modes" do
    D::SPLIT_MODES.each do |mode|
      mode.valid?.should be_true
      mode.label.should_not be_empty
    end
    D::SplitMode.new("foo").valid?.should be_false
    D::SplitMode.new("foo").label.should eq "foo"
    D::SPLIT_MODES.map(&.to_s).should eq %w(equal shares percent amount)
    D::SPLIT_MODES.map(&.label).should eq ["Gleichmäßig", "Nach Anteilen", "Nach Prozent", "Nach Beträgen"]
  end

  it "parses weights (parse_weight, weight_decimals)" do
    {"5" => 5, " 5 " => 5, "+5" => 5, "-3" => -3, "\t5" => 5}.each do |v, want|
      D.parse_weight(D::SPLIT_SHARES, "EUR", v).should eq want
    end
    {"1.5", "", "x", "\xff"}.each do |v|
      validation_error { D.parse_weight(D::SPLIT_SHARES, "EUR", v) }.should eq "Anteile müssen ganze Zahlen sein („#{v}“)."
    end
    D.parse_weight(D::SPLIT_AMOUNT, "JPY", "1.500").should eq 1500
    D.parse_weight(D::SPLIT_PERCENT, "JPY", "33,3").should eq 3330
    D.parse_weight(D::SPLIT_EQUAL, "JPY", "xyz").should eq 0
    D.weight_decimals(D::SPLIT_AMOUNT, "KWD").should eq 3
    D.weight_decimals(D::SPLIT_PERCENT, "KWD").should eq 2
    D.weight_decimals(D::SPLIT_SHARES, "KWD").should eq 0
  end

  it "reads and writes parts and shares as JSON" do
    D::Part.new(1, 2).to_json.should eq %({"participant_id":1,"weight":2})
    D::Share.from_json(%({"participant_id":3,"weight":1,"amount_cents":250})).should eq D::Share.new(3, 1, 250)
  end
end
