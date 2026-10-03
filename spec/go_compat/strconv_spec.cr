require "../spec_helper"

# Expected values were produced by Go 1.26.5 (the toolchain of go.mod).
# Additionally, 300,000 random floats and 300,000 random ParseFloat inputs
# were compared with Go once during the port.
private alias G = Zipfelkasse::GoCompat

describe Zipfelkasse::GoCompat do
  describe ".format_float and .json_float" do
    it "match strconv.FormatFloat(f, 'f', -1, 64) and encoding/json" do
      {
        0x0000000000000000_u64 => {"0", "0"},
        0x8000000000000000_u64 => {"-0", "-0"},
        0x3ff0000000000000_u64 => {"1", "1"},
        0xbff0000000000000_u64 => {"-1", "-1"},
        0x3ff8000000000000_u64 => {"1.5", "1.5"},
        0x40d09a0000000000_u64 => {"17000", "17000"},
        0x4415af1d78b58c40_u64 => {"100000000000000000000", "100000000000000000000"},
        0x444b1ae4d6e2ef50_u64 => {"1000000000000000000000", "1e+21"},
        0x4480f0cf064dd592_u64 => {"10000000000000000000000", "1e+22"},
        0x3eb0c6f7a0b5ed8d_u64 => {"0.000001", "0.000001"},
        0x3e7ad7f29abcaf48_u64 => {"0.0000001", "1e-7"},
        0x3ff166cf41f212d7_u64 => {"1.0876", "1.0876"},
        0x3feb645a1cac0831_u64 => {"0.856", "0.856"},
        0x419d6f3454800000_u64 => {"123456789.125", "123456789.125"},
        0x3e8421f5f40d8376_u64 => {"0.00000015", "1.5e-7"},
        0x3df12e0be826d695_u64 => {"0.00000000025", "2.5e-10"},
        0x3fd5555555555555_u64 => {"0.3333333333333333", "0.3333333333333333"},
        0x3fe5555555555555_u64 => {"0.6666666666666666", "0.6666666666666666"},
        0x40934a456d5cfaad_u64 => {"1234.5678", "1234.5678"},
        0x0000000000000001_u64 => {"0." + "0" * 323 + "5", "5e-324"},
        0x7fefffffffffffff_u64 => {"17976931348623157" + "0" * 292, "1.7976931348623157e+308"},
        0x54b249ad2594c37d_u64 => {"1" + "0" * 100, "1e+100"},
        0x444b1ae4d6e2ef4f_u64 => {"999999999999999900000", "999999999999999900000"},
        0x3c36b082c2148b8e_u64 => {"0.00000000000000000123", "1.23e-18"},
        0x3eb4b3fd5942cd96_u64 => {"0.000001234", "0.000001234"},
        0x43e56a95319d63e1_u64 => {"12345678901234567000", "12345678901234567000"},
        0x3fd3333333333334_u64 => {"0.30000000000000004", "0.30000000000000004"},
        0xbe7ad7f29abcaf48_u64 => {"-0.0000001", "-1e-7"},
        0xc44b1ae4d6e2ef50_u64 => {"-1000000000000000000000", "-1e+21"},
        0x430c6bf526340000_u64 => {"1000000000000000", "1000000000000000"},
        0x3ee9e409301b5a02_u64 => {"0.0000123456789", "0.0000123456789"},
        0x3eff75104d551d69_u64 => {"0.00003", "0.00003"},
      }.each do |bits, (fixed, json)|
        f = bits.unsafe_as(Float64)
        G.format_float(f).should eq fixed
        G.json_float(f).should eq json
      end
    end

    it "formats special values like FormatFloat and rejects them for JSON" do
      G.format_float(Float64::NAN).should eq "NaN"
      G.format_float(Float64::INFINITY).should eq "+Inf"
      G.format_float(-Float64::INFINITY).should eq "-Inf"
      expect_raises(ArgumentError) { G.json_float(Float64::NAN) }
      expect_raises(ArgumentError) { G.json_float(Float64::INFINITY) }
    end
  end

  describe ".parse_float" do
    it "accepts what strconv.ParseFloat accepts" do
      {
        "1" => 1.0, "1.5" => 1.5, "-1.5" => -1.5, "+1.5" => 1.5, ".5" => 0.5, "1." => 1.0,
        "-.5" => -0.5, "+.5" => 0.5, "007" => 7.0, "1e5" => 1e5, "1E5" => 1e5, "1e+5" => 1e5,
        "1e-5" => 1e-5, "1.5e3" => 1500.0, "Inf" => Float64::INFINITY, "+Inf" => Float64::INFINITY,
        "-Inf" => -Float64::INFINITY, "inf" => Float64::INFINITY, "INF" => Float64::INFINITY,
        "infinity" => Float64::INFINITY, "+infinity" => Float64::INFINITY,
        "-Infinity" => -Float64::INFINITY, "INFINITY" => Float64::INFINITY,
        "1_000" => 1000.0, "1_000.5" => 1000.5, "0x1p-2" => 0.25, "0X1P2" => 4.0, "0x1.8p1" => 3.0,
        "0x.8p1" => 1.0, "0x_1p0" => 1.0, "0x1_0p0" => 16.0, "1e-400" => 0.0, "2.4e-324" => 0.0,
        "4.9e-324" => 5e-324, "2.5e-324" => 5e-324, "1.7976931348623157e308" => Float64::MAX,
        "0.1" => 0.1, "0.000" => 0.0, "0e0" => 0.0, "0x1p-2000" => 0.0, "1e1_0" => 1e10, "0x1p1_0" => 1024.0,
        "123456789012345678901234567890" => 1.2345678901234568e+29,
        "1.0857" => 1.0857, "17000.50" => 17000.5, "0.8560" => 0.856,
      }.each do |input, want|
        G.parse_float(input).should eq want
      end
      %w(NaN nan NAN nAn).each { |s| G.parse_float(s).not_nil!.nan?.should be_true }
      G.parse_float("-0").not_nil!.sign_bit.should eq -1
    end

    it "rejects what strconv.ParseFloat rejects (including overflow)" do
      ["+NaN", "-nan", "infin", "infinityx", "Infx", "nanx", "_1", "1__0", "1_", "1_.5", "0x1", "0xp1",
       "0b101", "0o17", " 1", "1 ", "\t1", "1\n", "", "+", "-", ".", "e5", "1e", "1e+", "1e5.5", "1.2.3",
       "1,5", "--1", "+-1", "１", "1e400", "-1e400", "1.7976931348623159e308", "0x1p2000", "0x"].each do |s|
        G.parse_float(s).should be_nil
      end
    end
  end

  describe ".parse_int" do
    it "behaves like strconv.ParseInt(s, 10, 64)" do
      G.parse_int("+5").should eq 5
      G.parse_int("-3").should eq -3
      G.parse_int("007").should eq 7
      G.parse_int("-9223372036854775808").should eq Int64::MIN
      ["", " 1", "1 ", "1_000", "0x10", "9223372036854775808", "+", "1.0", "١"].each do |s|
        G.parse_int(s).should be_nil
      end
    end
  end
end
