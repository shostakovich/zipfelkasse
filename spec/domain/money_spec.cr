require "../spec_helper"

describe Domain do
  describe ".format_cents" do
    {
      0_i64 => "0,00 €", 1_i64 => "0,01 €", 99_i64 => "0,99 €", 1234_i64 => "12,34 €", 100000_i64 => "1.000,00 €",
      123456789_i64 => "1.234.567,89 €", -1234_i64 => "-12,34 €", -5_i64 => "-0,05 €",
      Int64::MAX => "92.233.720.368.547.758,07 €",
    }.each do |cents, text|
      it "writes #{cents} cents as #{text}" do
        Domain.format_cents(cents).should eq text
      end
    end
  end

  describe ".format_cents_input" do
    {0_i64 => "0,00", 1234_i64 => "12,34", 123456_i64 => "1234,56", -50_i64 => "-0,50"}.each do |cents, text|
      it "writes #{cents} cents for an input field as #{text}" do
        Domain.format_cents_input(cents).should eq text
      end
    end
  end

  describe ".parse_cents" do
    {
      "12,34" => 1234, "12.34" => 1234, "12" => 1200, "12,3" => 1230, "12.5" => 1250, ",50" => 50, ".5" => 50, "0" => 0,
      "-0" => 0, " 12,34 € " => 1234, "12,34€" => 1234, "1.234,56" => 123456, "1,234.56" => 123456, "1,234,567.8" => 123456780,
      "1.234" => 123400, "1.234.567" => 123456700, "1.234.567,89" => 123456789, "0.50" => 50, "-12,34" => -1234, "+3" => 300,
      "1.0000" => 100, "1\u{a0}000" => 100000, "\t1,5\u{a0}" => 150,
    }.each do |text, cents|
      it "reads #{text.inspect} as #{cents} cents" do
        Domain.parse_cents(text).should eq cents
      end
    end

    {
      ""                     => "Bitte einen Betrag eingeben.",
      " € "                  => "Bitte einen Betrag eingeben.",
      "   "                  => "Bitte einen Betrag eingeben.",
      "abc"                  => "Ungültiger Betrag „abc“.",
      "1 2,3x"               => "Ungültiger Betrag „12,3x“.",
      "1,2,3"                => "Ungültiger Betrag „1,2,3“.",
      "12.34.5"              => "Ungültiger Betrag „12.34.5“.",
      "1.23,4"               => "Ungültiger Betrag „1.23,4“.",
      "1.234.5"              => "Ungültiger Betrag „1.234.5“.",
      "1.2.3,4"              => "Ungültiger Betrag „1.2.3,4“.",
      "1..2"                 => "Ungültiger Betrag „1..2“.",
      "12,"                  => "Ungültiger Betrag „12,“.",
      "0,"                   => "Ungültiger Betrag „0,“.",
      "-"                    => "Ungültiger Betrag „-“.",
      "+"                    => "Ungültiger Betrag „+“.",
      "+-1"                  => "Ungültiger Betrag „+-1“.",
      "--1"                  => "Ungültiger Betrag „--1“.",
      "€12"                  => "Ungültiger Betrag „€12“.",
      "12 €€"                => "Ungültiger Betrag „12€“.",
      "1\u{202f}000"         => "Ungültiger Betrag „1\u{202f}000“.",
      "\u{661}\u{662}"       => "Ungültiger Betrag „\u{661}\u{662}“.",
      "12,345"               => "Höchstens 2 Nachkommastellen erlaubt.",
      "1,234"                => "Höchstens 2 Nachkommastellen erlaubt.",
      "0.123"                => "Höchstens 2 Nachkommastellen erlaubt.",
      "000.123"              => "Höchstens 2 Nachkommastellen erlaubt.",
      "12.3456"              => "Höchstens 2 Nachkommastellen erlaubt.",
      "1" * 16               => "Der Betrag ist zu groß.",
      "99999999999999999999" => "Der Betrag ist zu groß.",
    }.each do |text, message|
      it "rejects #{text.inspect} with #{message.inspect}" do
        expect_invalid(message) { Domain.parse_cents(text) }
      end
    end
  end

  describe ".parse_minor" do
    {
      {"1500", 0} => 1500, {"1.500", 0} => 1500, {"1,234", 3} => 1234, {"1.5", 3} => 1500, {"0.123", 3} => 123,
      {"1200,00", 0} => 1200, {"1.200,00", 0} => 1200, {"12,340", 2} => 1234,
    }.each do |(text, decimals), minor|
      it "reads #{text.inspect} with #{decimals} decimals as #{minor}" do
        Domain.parse_minor(text, decimals).should eq minor
      end
    end

    {"15,5", "0.500", "1200,50", "1.500,5"}.each do |text|
      it "rejects #{text.inspect} in a currency without decimals" do
        expect_invalid("Dieser Betrag darf keine Nachkommastellen haben.") { Domain.parse_minor(text, 0) }
      end
    end

    it "rejects too many decimals" do
      expect_invalid("Höchstens 2 Nachkommastellen erlaubt.") { Domain.parse_minor("12,345", 2) }
    end
  end

  describe ".parse_basis_points" do
    {"50" => 5000, "33,33" => 3333, "33.34" => 3334, "100" => 10000, "12,5 %" => 1250, "-5" => -500}.each do |text, points|
      it "reads #{text.inspect} as #{points} basis points" do
        Domain.parse_basis_points(text).should eq points
      end
    end

    {" x % " => "x", "%" => "", "50%%" => "50%", "100,001" => "100,001"}.each do |text, shown|
      it "rejects #{text.inspect}" do
        expect_invalid("Ungültige Prozentangabe „#{shown}“.") { Domain.parse_basis_points(text) }
      end
    end

    it "writes basis points as a percentage" do
      Domain.format_basis_points(3333).should eq "33,33 %"
      Domain.format_basis_points(10000).should eq "100,00 %"
    end
  end

  describe ".format_money" do
    {
      {1234_i64, "EUR"} => "12,34 €", {1234_i64, ""} => "12,34 €", {1234_i64, "USD"} => "12,34 USD",
      {123456_i64, "JPY"} => "123.456 JPY", {1234_i64, "kwd"} => "1,234 KWD", {-123456789_i64, " usd "} => "-1.234.567,89 USD",
    }.each do |(minor, currency), text|
      it "writes #{minor} in #{currency.inspect} as #{text}" do
        Domain.format_money(minor, currency).should eq text
      end
    end
  end

  describe ".valid_currency_code?" do
    {"USD" => true, "EUR" => true, "JPY" => true, "usd" => false, "U$D" => false, "US" => false, "USDD" => false, "" => false,
     " USD" => false, "ÄBC" => false}.each do |code, valid|
      it "#{valid ? "accepts" : "rejects"} #{code.inspect}" do
        Domain.valid_currency_code?(code).should eq valid
      end
    end
  end

  describe ".eur?" do
    {"" => true, "EUR" => true, "eur" => true, " EUR " => true, "USD" => false, "EU" => false}.each do |currency, euro|
      it "#{euro ? "recognizes" : "does not recognize"} #{currency.inspect} as euros" do
        Domain.eur?(currency).should eq euro
      end
    end
  end

  describe ".to_eur_cents" do
    {
      {10000_i64, "USD", 1.0823}  => 9240,
      {1000_i64, "JPY", 160.5}    => 623,
      {1234_i64, "EUR", 1.0}      => 1234,
      {-10000_i64, "USD", 1.0823} => -9240,
      {5_i64, "EUR", 2.0}         => 3,
      {-5_i64, "EUR", 2.0}        => -3,
    }.each do |(minor, currency, rate), cents|
      it "converts #{minor} #{currency} at #{rate} to #{cents} cents, rounding half away from zero" do
        Domain.to_eur_cents(minor, currency, rate).should eq cents
      end
    end

    it "refuses an amount that is too large after the conversion" do
      expect_invalid("Der Betrag ist zu groß.") { Domain.to_eur_cents(Domain::MAX_AMOUNT_CENTS, "USD", 1e-12) }
    end

    [Float64::INFINITY, Float64::NAN, 0.0, -1.0].each do |rate|
      it "refuses the rate #{rate}" do
        expect_invalid("Der Wechselkurs muss größer als 0 sein.") { Domain.to_eur_cents(100, "USD", rate) }
      end
    end
  end

  describe ".parse_rate" do
    {
      "1,0857" => 1.0857, "1.0857" => 1.0857, "17000" => 17000.0, "17.000,5" => 17000.5, "17,000.5" => 17000.5,
      "00.856" => 0.856, "0.8565" => 0.8565, "1.234.567,25" => 1234567.25, " 0,8653 " => 0.8653, "162,45" => 162.45,
      "1,5" => 1.5, "1 000,5" => 1000.5, "123456789012,5" => 123456789012.5, "0,000000000001" => 1e-12,
    }.each do |text, rate|
      it "reads #{text.inspect} as #{rate}" do
        Domain.parse_rate(text).should eq rate
      end
    end

    {"17.000" => 17000.0, "1.085" => 1085.0}.each do |text, rate|
      it "reads the dot before exactly three digits in #{text.inspect} as a thousands separator, as for amounts" do
        Domain.parse_rate(text).should eq rate
      end
    end

    {"0.856" => 0.856, "0.8565" => 0.8565}.each do |text, rate|
      it "reads the dot after a leading 0 in #{text.inspect} as a decimal point" do
        Domain.parse_rate(text).should eq rate
      end
    end

    ["", "0", "0,0", "-1,2", "abc", "1,2,3", "1.2.3", "17.00.0", "1e5", "NaN", "Inf", "1,", ",5x", "0.000",
     "1234567890123", "0,0000000000001"].each do |text|
      it "rejects #{text.inspect}" do
        expect_raises(Domain::ValidationError, "Ungültiger Wechselkurs „#{text.gsub(' ', "")}“") { Domain.parse_rate(text) }
      end
    end
  end

  describe ".format_decimal" do
    {
      {0_i64, 2, ','} => "0,00", {5_i64, 2, ','} => "0,05", {123456_i64, 2, ','} => "1234,56", {-42_i64, 2, ','} => "-0,42",
      {1500_i64, 0, ','} => "1500", {1234_i64, 3, ','} => "1,234", {-5_i64, 2, '.'} => "-0.05", {-300000_i64, 2, '.'} => "-3000.00",
      {-7_i64, 0, '.'} => "-7", {12345_i64, 3, '.'} => "12.345",
    }.each do |(value, decimals, separator), text|
      it "writes #{value} with #{decimals} decimals and #{separator.inspect} as #{text}" do
        Domain.format_decimal(value, decimals, separator).should eq text
      end
    end
  end

  describe ".format_minor_input" do
    {"USD" => "1234,56", "JPY" => "123456", "KWD" => "123,456", "EUR" => "1234,56"}.each do |currency, text|
      it "writes 123456 minor units of #{currency} as #{text}" do
        Domain.format_minor_input(123456, currency).should eq text
      end
    end
  end

  describe ".format_rate" do
    {1.0876 => "1,0876", 17000.0 => "17000", 0.856 => "0,856", 1e-7 => "0,0000001", 1e21 => "1000000000000000000000",
     0.0 => "", -1.0 => "", Float64::NAN => ""}.each do |rate, text|
      it "writes the rate #{rate} as #{text.inspect}" do
        Domain.format_rate(rate).should eq text
      end
    end
  end
end
