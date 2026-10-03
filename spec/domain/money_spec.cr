require "../spec_helper"

private alias D = Zipfelkasse::Domain

describe Zipfelkasse::Domain do
  it "formats cents" do
    {
              0_i64 => "0,00 €",
              1_i64 => "0,01 €",
             99_i64 => "0,99 €",
           1234_i64 => "12,34 €",
         100000_i64 => "1.000,00 €",
      123456789_i64 => "1.234.567,89 €",
          -1234_i64 => "-12,34 €",
             -5_i64 => "-0,05 €",
    }.each { |cents, want| D.format_cents(cents).should eq want }
  end

  it "formats cents for inputs" do
    {0_i64 => "0,00", 1234_i64 => "12,34", 123456_i64 => "1234,56", -50_i64 => "-0,50"}.each do |cents, want|
      D.format_cents_input(cents).should eq want
    end
  end

  it "parses cents" do
    {
      "12,34"        => 1234_i64,
      "12.34"        => 1234_i64,
      "12"           => 1200_i64,
      "12,3"         => 1230_i64,
      "12.5"         => 1250_i64,
      ",50"          => 50_i64,
      "0"            => 0_i64,
      " 12,34 € "    => 1234_i64,
      "12,34€"       => 1234_i64,
      "1.234,56"     => 123456_i64,
      "1,234.56"     => 123456_i64,
      "1.234"        => 123400_i64,
      "1.234.567"    => 123456700_i64,
      "1.234.567,89" => 123456789_i64,
      "0.50"         => 50_i64,
      "-12,34"       => -1234_i64,
      "+3"           => 300_i64,
    }.each { |input, want| D.parse_cents(input).should eq want }
    # "0.123": after a leading 0 the dot is a decimal point: too many decimals
    ["0.123", "", "   ", "abc", "12,345", "1,2,3", "12.34.5", "1.23,4", "12,", "-", "99999999999999999999"].each do |input|
      expect_raises(D::ValidationError) { D.parse_cents(input) }
    end
  end

  it "parses amounts with other decimals" do
    {
      {"1500", 0}     => 1500_i64,
      {"1.500", 0}    => 1500_i64,
      {"1,234", 3}    => 1234_i64,
      {"1.5", 3}      => 1500_i64,
      {"0.123", 3}    => 123_i64,
      {"1200,00", 0}  => 1200_i64, # superfluous zeros are fine, e.g. after switching from EUR to JPY
      {"1.200,00", 0} => 1200_i64,
      {"12,340", 2}   => 1234_i64,
    }.each { |(input, decimals), want| D.parse_minor(input, decimals).should eq want }
    # "0.500" with 0 decimals is 0.5 yen, not 500 yen
    [{"15,5", 0}, {"0.500", 0}, {"1200,50", 0}, {"12,345", 2}].each do |input, decimals|
      expect_raises(D::ValidationError) { D.parse_minor(input, decimals) }
    end
  end

  it "parses and formats basis points" do
    {"50" => 5000_i64, "33,33" => 3333_i64, "33.34" => 3334_i64, "100" => 10000_i64, "12,5 %" => 1250_i64}.each do |input, want|
      D.parse_basis_points(input).should eq want
    end
    D.format_basis_points(3333).should eq "33,33 %"
    D.format_basis_points(10000).should eq "100,00 %"
  end

  it "formats money in any currency" do
    {
      {1234_i64, "EUR"}   => "12,34 €",
      {1234_i64, ""}      => "12,34 €",
      {1234_i64, "USD"}   => "12,34 USD",
      {123456_i64, "JPY"} => "123.456 JPY",
      {1234_i64, "kwd"}   => "1,234 KWD",
    }.each { |(minor, currency), want| D.format_money(minor, currency).should eq want }
  end

  it "validates currency codes" do
    {
      "USD" => true, "EUR" => true, "JPY" => true,
      "usd" => false, "U$D" => false, "US" => false, "USDD" => false, "" => false, " USD" => false, "ÄBC" => false,
    }.each { |code, want| D.valid_currency_code?(code).should eq want }
  end

  it "recognizes euros" do
    {"" => true, "EUR" => true, "eur" => true, " EUR " => true, "USD" => false, "EU" => false}.each do |currency, want|
      D.eur?(currency).should eq want
    end
  end

  it "converts to euro cents" do
    {
      {10000_i64, "USD", 1.0823}  => 9240_i64, # 100 USD / 1.0823 = 92.396... €
      {1000_i64, "JPY", 160.5}    => 623_i64,  # 1000 JPY / 160.5 = 6.2305 €
      {1234_i64, "EUR", 1.0}      => 1234_i64,
      {-10000_i64, "USD", 1.0823} => -9240_i64,
      {100_i64, "USD", 0.0}       => 0_i64, # invalid rate
    }.each { |(minor, currency, rate), want| D.to_eur_cents(minor, currency, rate).should eq want }
  end

  it "parses exchange rates" do
    {
      "1,0857"       => 1.0857,
      "1.0857"       => 1.0857,
      "17000"        => 17000.0,
      "17.000,5"     => 17000.5,
      "17,000.5"     => 17000.5,
      "17.000"       => 17000.0, # dot before exactly three digits = thousands (as for amounts)
      "1.085"        => 1085.0,
      "0.856"        => 0.856, # ... but not after a leading 0
      "00.856"       => 0.856,
      "0.8565"       => 0.8565,
      "1.234.567,25" => 1234567.25,
      " 0,8653 "     => 0.8653,
      "162,45"       => 162.45,
      "1,5"          => 1.5,
    }.each { |input, want| D.parse_rate(input).should eq want }
    ["", "0", "0,0", "-1,2", "abc", "1,2,3", "1.2.3", "17.00.0", "1e5", "NaN", "Inf", "1,", ",5x", "0.000"].each do |input|
      expect_raises(D::ValidationError) { D.parse_rate(input) }
    end
  end

  it "formats decimals" do
    [
      {0_i64, 2, ',', "0,00"}, {5_i64, 2, ',', "0,05"}, {123456_i64, 2, ',', "1234,56"}, {-42_i64, 2, ',', "-0,42"},
      {1500_i64, 0, ',', "1500"}, {1234_i64, 3, ',', "1,234"},
      {-5_i64, 2, '.', "-0.05"}, {-300000_i64, 2, '.', "-3000.00"}, {-7_i64, 0, '.', "-7"}, {12345_i64, 3, '.', "12.345"},
    ].each { |(v, decimals, sep, want)| D.format_decimal(v, decimals, sep).should eq want }
    {"USD" => "1234,56", "JPY" => "123456", "KWD" => "123,456", "EUR" => "1234,56"}.each do |currency, want|
      D.format_minor_input(123456, currency).should eq want
    end
  end

  it "formats exchange rates" do
    {1.0876 => "1,0876", 17000.0 => "17000", 0.856 => "0,856", 0.0 => "", -1.0 => ""}.each do |rate, want|
      D.format_rate(rate).should eq want
    end
  end

  describe "edge cases" do
    it "formats Int64::MIN and large groups" do
      D.format_cents(Int64::MIN).should eq "-92.233.720.368.547.758,08 €"
      D.format_cents(Int64::MAX).should eq "92.233.720.368.547.758,07 €"
      D.format_money(-123456789, " usd ").should eq "-1.234.567,89 USD"
      D.format_rate(1e-7).should eq "0,0000001"
      D.format_rate(1e21).should eq "1000000000000000000000"
      D.format_rate(Float64::NAN).should eq ""
    end

    it "parses amounts and reports errors" do
      {
        ""               => "Bitte einen Betrag eingeben.",
        " € "            => "Bitte einen Betrag eingeben.",
        "1 2,3x"         => "Ungültiger Betrag „12,3x“.",
        "1,234"          => "Höchstens 2 Nachkommastellen erlaubt.",
        "1" * 16         => "Der Betrag ist zu groß.",
        "1\u{a0}000"     => 100000_i64,
        "1\u{202f}000"   => "Ungültiger Betrag „1\u{202f}000“.", # only space and NBSP are removed
        "€12"            => "Ungültiger Betrag „€12“.",
        "12 €€"          => "Ungültiger Betrag „12€“.",
        "-0"             => 0_i64,
        "+-1"            => "Ungültiger Betrag „+-1“.",
        "--1"            => "Ungültiger Betrag „--1“.",
        "1.2.3,4"        => "Ungültiger Betrag „1.2.3,4“.",
        "1,234,567.8"    => 123456780_i64,
        ".5"             => 50_i64,
        "0,"             => "Ungültiger Betrag „0,“.",
        "000.123"        => "Höchstens 2 Nachkommastellen erlaubt.",
        "1.0000"         => 100_i64,
        "12.3456"        => "Höchstens 2 Nachkommastellen erlaubt.",
        "1..2"           => "Ungültiger Betrag „1..2“.",
        "\t1,5\u{a0}"    => 150_i64,
        "1.234.5"        => "Ungültiger Betrag „1.234.5“.",
        "+"              => "Ungültiger Betrag „+“.",
        "1\xff"          => "Ungültiger Betrag „1\xff“.",
        "\u{661}\u{662}" => "Ungültiger Betrag „\u{661}\u{662}“.",
      }.each do |input, want|
        if want.is_a?(String)
          validation_error { D.parse_cents(input) }.should eq want
        else
          D.parse_cents(input).should eq want
        end
      end
      validation_error { D.parse_minor("1,5", 0) }.should eq "Dieser Betrag darf keine Nachkommastellen haben."
      validation_error { D.parse_minor("1.500,5", 0) }.should eq "Dieser Betrag darf keine Nachkommastellen haben."
    end

    it "parses basis points and rates" do
      validation_error { D.parse_basis_points(" x % ") }.should eq "Ungültige Prozentangabe „x“."
      validation_error { D.parse_basis_points("%") }.should eq "Ungültige Prozentangabe „“."
      validation_error { D.parse_basis_points("50%%") }.should eq "Ungültige Prozentangabe „50%“."
      validation_error { D.parse_basis_points("100,001") }.should eq "Ungültige Prozentangabe „100,001“."
      D.parse_basis_points("-5").should eq -500
      validation_error { D.parse_rate(" - 1,2") }.should eq "Ungültiger Wechselkurs „-1,2“ – bitte eine Zahl größer als 0 angeben (Einheiten der Währung pro 1 €)."
      validation_error { D.parse_rate("1234567890123") }.should contain "„1234567890123“"
      validation_error { D.parse_rate("0,0000000000001") }.should contain "„0,0000000000001“"
      D.parse_rate("1 000,5").should eq 1000.5
      D.parse_rate("123456789012,5").should eq 123456789012.5
      D.parse_rate("0,000000000001").should eq 1e-12
    end

    it "handles absurd rates and rounds half away from zero" do
      D.to_eur_cents(MAX_CENTS, "USD", 1e-12).should eq Int64::MIN # out of Int64 range
      D.to_eur_cents(5, "EUR", 2.0).should eq 3
      D.to_eur_cents(-5, "EUR", 2.0).should eq -3
      D.to_eur_cents(100, "USD", Float64::INFINITY).should eq 0
      D.to_eur_cents(100, "USD", Float64::NAN).should eq 0
    end
  end
end

private MAX_CENTS = Zipfelkasse::Domain::MAX_AMOUNT_CENTS

private def validation_error(&) : String
  yield
  fail "expected a ValidationError"
rescue e : Zipfelkasse::Domain::ValidationError
  e.msg
end
