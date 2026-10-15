defmodule Zipfelkasse.MoneyTest do
  use ExUnit.Case, async: true

  alias Zipfelkasse.Money

  describe "format_cents/1" do
    for {cents, text} <- [
          {0, "0,00 €"},
          {1, "0,01 €"},
          {99, "0,99 €"},
          {1234, "12,34 €"},
          {100_000, "1.000,00 €"},
          {123_456_789, "1.234.567,89 €"},
          {-1234, "-12,34 €"},
          {-5, "-0,05 €"},
          {9_223_372_036_854_775_807, "92.233.720.368.547.758,07 €"}
        ] do
      test "writes #{cents} cents as #{text}" do
        assert Money.format_cents(unquote(cents)) == unquote(text)
      end
    end
  end

  describe "format_cents_input/1" do
    for {cents, text} <- [{0, "0,00"}, {1234, "12,34"}, {123_456, "1234,56"}, {-50, "-0,50"}] do
      test "writes #{cents} cents for an input field as #{text}" do
        assert Money.format_cents_input(unquote(cents)) == unquote(text)
      end
    end
  end

  describe "parse/2 with two decimals" do
    for {text, cents} <- [
          {"12,34", 1234},
          {"12.34", 1234},
          {"12", 1200},
          {"12,3", 1230},
          {"12.5", 1250},
          {",50", 50},
          {".5", 50},
          {"0", 0},
          {"-0", 0},
          {" 12,34 € ", 1234},
          {"12,34€", 1234},
          {"1.234,56", 123_456},
          {"1,234.56", 123_456},
          {"1,234,567.8", 123_456_780},
          {"1.234", 123_400},
          {"1.234.567", 123_456_700},
          {"1.234.567,89", 123_456_789},
          {"0.50", 50},
          {"-12,34", -1234},
          {"+3", 300},
          {"1.0000", 100},
          {"1 000", 100_000},
          {"\t1,5 ", 150}
        ] do
      test "reads #{inspect(text)} as #{cents} cents" do
        assert Money.parse(unquote(text), 2) == {:ok, unquote(cents)}
      end
    end

    for {text, message} <- [
          {"", "Bitte einen Betrag eingeben."},
          {" € ", "Bitte einen Betrag eingeben."},
          {"   ", "Bitte einen Betrag eingeben."},
          {"abc", "Ungültiger Betrag „abc“."},
          {"1 2,3x", "Ungültiger Betrag „12,3x“."},
          {"1,2,3", "Ungültiger Betrag „1,2,3“."},
          {"12.34.5", "Ungültiger Betrag „12.34.5“."},
          {"1.23,4", "Ungültiger Betrag „1.23,4“."},
          {"1.234.5", "Ungültiger Betrag „1.234.5“."},
          {"1.2.3,4", "Ungültiger Betrag „1.2.3,4“."},
          {"1..2", "Ungültiger Betrag „1..2“."},
          {"12,", "Ungültiger Betrag „12,“."},
          {"0,", "Ungültiger Betrag „0,“."},
          {"-", "Ungültiger Betrag „-“."},
          {"+", "Ungültiger Betrag „+“."},
          {"+-1", "Ungültiger Betrag „+-1“."},
          {"--1", "Ungültiger Betrag „--1“."},
          {"€12", "Ungültiger Betrag „€12“."},
          {"12 €€", "Ungültiger Betrag „12€“."},
          {"1 000", "Ungültiger Betrag „1 000“."},
          {"١٢", "Ungültiger Betrag „١٢“."},
          {"12,345", "Höchstens 2 Nachkommastellen erlaubt."},
          {"1,234", "Höchstens 2 Nachkommastellen erlaubt."},
          {"0.123", "Höchstens 2 Nachkommastellen erlaubt."},
          {"000.123", "Höchstens 2 Nachkommastellen erlaubt."},
          {"12.3456", "Höchstens 2 Nachkommastellen erlaubt."},
          {String.duplicate("1", 16), "Der Betrag ist zu groß."},
          {"99999999999999999999", "Der Betrag ist zu groß."}
        ] do
      test "rejects #{inspect(text)}" do
        assert Money.parse(unquote(text), 2) == {:error, unquote(message)}
      end
    end
  end

  describe "parse/2" do
    for {text, decimals, minor} <- [
          {"1500", 0, 1500},
          {"1.500", 0, 1500},
          {"1,234", 3, 1234},
          {"1.5", 3, 1500},
          {"0.123", 3, 123},
          {"1200,00", 0, 1200},
          {"1.200,00", 0, 1200},
          {"12,340", 2, 1234}
        ] do
      test "reads #{inspect(text)} with #{decimals} decimals as #{minor}" do
        assert Money.parse(unquote(text), unquote(decimals)) == {:ok, unquote(minor)}
      end
    end

    for text <- ["15,5", "0.500", "1200,50", "1.500,5"] do
      test "rejects #{inspect(text)} in a currency without decimals" do
        assert Money.parse(unquote(text), 0) ==
                 {:error, "Dieser Betrag darf keine Nachkommastellen haben."}
      end
    end
  end

  describe "parse_basis_points/1" do
    for {text, points} <- [
          {"50", 5000},
          {"33,33", 3333},
          {"33.34", 3334},
          {"100", 10_000},
          {"12,5 %", 1250},
          {"-5", -500}
        ] do
      test "reads #{inspect(text)} as #{points} basis points" do
        assert Money.parse_basis_points(unquote(text)) == {:ok, unquote(points)}
      end
    end

    for {text, shown} <- [{" x % ", "x"}, {"%", ""}, {"50%%", "50%"}, {"100,001", "100,001"}] do
      test "rejects #{inspect(text)}" do
        assert Money.parse_basis_points(unquote(text)) ==
                 {:error, "Ungültige Prozentangabe „#{unquote(shown)}“."}
      end
    end

    test "writes basis points as a percentage" do
      assert Money.format_basis_points(3333) == "33,33 %"
      assert Money.format_basis_points(10_000) == "100,00 %"
    end
  end

  describe "format_money/2" do
    for {minor, currency, text} <- [
          {1234, "EUR", "12,34 €"},
          {1234, "", "12,34 €"},
          {1234, "USD", "12,34 USD"},
          {123_456, "JPY", "123.456 JPY"},
          {1234, "kwd", "1,234 KWD"},
          {-123_456_789, " usd ", "-1.234.567,89 USD"}
        ] do
      test "writes #{minor} in #{inspect(currency)} as #{text}" do
        assert Money.format_money(unquote(minor), unquote(currency)) == unquote(text)
      end
    end
  end

  describe "valid_currency?/1" do
    for {code, valid?} <- [
          {"USD", true},
          {"EUR", true},
          {"JPY", true},
          {"usd", false},
          {"U$D", false},
          {"US", false},
          {"USDD", false},
          {"", false},
          {" USD", false},
          {"ÄBC", false}
        ] do
      test "#{if valid?, do: "accepts", else: "rejects"} #{inspect(code)}" do
        assert Money.valid_currency?(unquote(code)) == unquote(valid?)
      end
    end
  end

  test "normalizes a currency code, also for its decimals" do
    assert Money.normalize_currency(" usd\n") == "USD"
    assert Money.decimals(" jpy ") == 0
  end

  describe "eur?/1" do
    for {currency, euro?} <- [
          {"", true},
          {"EUR", true},
          {"eur", true},
          {" EUR ", true},
          {"USD", false},
          {"EU", false}
        ] do
      test "#{if euro?, do: "recognizes", else: "does not recognize"} #{inspect(currency)} as euros" do
        assert Money.eur?(unquote(currency)) == unquote(euro?)
      end
    end
  end

  describe "to_eur_cents/3" do
    for {minor, currency, rate, cents} <- [
          {10_000, "USD", 1.0823, 9240},
          {1000, "JPY", 160.5, 623},
          {1234, "EUR", 1.0, 1234},
          {-10_000, "USD", 1.0823, -9240},
          {5, "EUR", 2.0, 3},
          {-5, "EUR", 2.0, -3}
        ] do
      test "converts #{minor} #{currency} at #{rate} to #{cents} cents, rounding half away from zero" do
        assert Money.to_eur_cents(unquote(minor), unquote(currency), unquote(rate)) ==
                 {:ok, unquote(cents)}
      end
    end

    test "refuses an amount that is too large after the conversion" do
      assert Money.to_eur_cents(Money.max_cents(), "USD", 1.0e-12) ==
               {:error, "Der Betrag ist zu groß."}
    end

    for rate <- [0.0, -1.0, nil] do
      test "refuses the rate #{inspect(rate)}" do
        assert Money.to_eur_cents(100, "USD", unquote(rate)) ==
                 {:error, "Der Wechselkurs muss größer als 0 sein."}
      end
    end
  end

  describe "parse_rate/1" do
    for {text, rate} <- [
          {"1,0857", 1.0857},
          {"1.0857", 1.0857},
          {"17000", 17_000.0},
          {"17.000,5", 17_000.5},
          {"17,000.5", 17_000.5},
          {"00.856", 0.856},
          {"0.8565", 0.8565},
          {"1.234.567,25", 1_234_567.25},
          {" 0,8653 ", 0.8653},
          {"162,45", 162.45},
          {"1,5", 1.5},
          {"1 000,5", 1000.5},
          {"123456789012,5", 123_456_789_012.5},
          {"0,000000000001", 1.0e-12},
          {"17.000", 17_000.0},
          {"1.085", 1085.0},
          {"0.856", 0.856}
        ] do
      test "reads #{inspect(text)} as #{rate}" do
        assert Money.parse_rate(unquote(text)) == {:ok, unquote(rate)}
      end
    end

    for text <- [
          "",
          "0",
          "0,0",
          "-1,2",
          "abc",
          "1,2,3",
          "1.2.3",
          "17.00.0",
          "1e5",
          "NaN",
          "Inf",
          "1,",
          ",5x",
          "0.000",
          "1234567890123",
          "0,0000000000001"
        ] do
      test "rejects #{inspect(text)}" do
        assert {:error, "Ungültiger Wechselkurs „" <> rest} = Money.parse_rate(unquote(text))
        assert String.starts_with?(rest, String.replace(unquote(text), " ", "") <> "“")
      end
    end
  end

  describe "parse_decimal/2" do
    for {text, decimals, minor} <- [
          {"23.40", 2, 2340},
          {"1234.56", 2, 123_456},
          {" 12 ", 2, 1200},
          {"12.", 2, 1200},
          {"1.000", 0, 1},
          {"0.125", 3, 125}
        ] do
      test "reads #{inspect(text)} with #{decimals} decimals as #{minor}" do
        assert Money.parse_decimal(unquote(text), unquote(decimals)) == {:ok, unquote(minor)}
      end
    end

    for text <- [
          "1.234",
          "1,5",
          "-1",
          "+1",
          "",
          ".5",
          "1.2.3",
          "1 000",
          String.duplicate("1", 16)
        ] do
      test "rejects #{inspect(text)}" do
        assert Money.parse_decimal(unquote(text), 2) == :error
      end
    end
  end

  describe "format_minor/3" do
    for {value, decimals, separator, text} <- [
          {0, 2, ",", "0,00"},
          {5, 2, ",", "0,05"},
          {123_456, 2, ",", "1234,56"},
          {-42, 2, ",", "-0,42"},
          {1500, 0, ",", "1500"},
          {1234, 3, ",", "1,234"},
          {-5, 2, ".", "-0.05"},
          {-300_000, 2, ".", "-3000.00"},
          {-7, 0, ".", "-7"},
          {12_345, 3, ".", "12.345"}
        ] do
      test "writes #{value} with #{decimals} decimals and #{inspect(separator)} as #{text}" do
        assert Money.format_minor(unquote(value), unquote(decimals),
                 separator: unquote(separator)
               ) ==
                 unquote(text)
      end
    end

    test "groups thousands with dots" do
      assert Money.format_minor(-123_456_789, 2, group: true) == "-1.234.567,89"
    end
  end

  describe "format_minor_input/2" do
    for {currency, text} <- [
          {"USD", "1234,56"},
          {"JPY", "123456"},
          {"KWD", "123,456"},
          {"EUR", "1234,56"}
        ] do
      test "writes 123456 minor units of #{currency} as #{text}" do
        assert Money.format_minor_input(123_456, unquote(currency)) == unquote(text)
      end
    end
  end

  describe "format_rate/1" do
    for {rate, text} <- [
          {1.0876, "1,0876"},
          {17_000.0, "17000"},
          {0.856, "0,856"},
          {1.0e-7, "0,0000001"},
          {1.0e21, "1000000000000000000000"},
          {123_456_789_012.5, "123456789012,5"},
          {0.0, ""},
          {-1.0, ""}
        ] do
      test "writes the rate #{rate} as #{inspect(text)}" do
        assert Money.format_rate(unquote(rate)) == unquote(text)
      end
    end
  end
end
