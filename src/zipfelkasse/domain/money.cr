# Zipfelkasse's pure business logic: money, splitting, balances, settlement
# and recurrence rules. No IO, no dependencies.
#
# Go name (package domain) → Crystal name (module Zipfelkasse::Domain)
# ValidCurrencyCode        → valid_currency_code?
# IsEUR                    → eur?
# (value, error) results   → value, raising ValidationError
module Zipfelkasse::Domain
  extend self

  # Amounts are Int64 in the smallest unit everywhere (cents for EUR).

  # Caps amounts so that multiplications during splitting cannot overflow
  # (10 billion €).
  MAX_AMOUNT_CENTS = 1_000_000_000_000_i64

  # An input error with a German, user-readable message. Handlers show the
  # message directly in the form.
  class ValidationError < Exception
    getter msg : String

    def initialize(@msg : String)
      super(@msg)
    end
  end

  # Formats cents as a German euro amount: 123456 → "1.234,56 €".
  def format_cents(c : Int64) : String
    format_fixed(c, 2, true) + " €"
  end

  # Formats cents for an input field, without thousands separators and
  # without currency symbol: 123456 → "1234,56".
  def format_cents_input(c : Int64) : String
    format_fixed(c, 2, false)
  end

  # Formats an amount given in the currency's smallest unit:
  # (1234, "USD") → "12,34 USD", EUR or "" → "12,34 €".
  def format_money(minor : Int64, currency : String) : String
    return format_cents(minor) if eur?(currency)
    currency = GoCompat.to_upper(GoCompat.trim_space(currency))
    format_fixed(minor, currency_decimals(currency), true) + " " + currency
  end

  # Formats basis points as a percentage: 3333 → "33,33 %".
  def format_basis_points(bp : Int64) : String
    format_fixed(bp, 2, false) + " %"
  end

  # Parses a euro amount such as "12,34", "12.34", "1.234,56 €".
  def parse_cents(s : String) : Int64
    parse_minor(s, 2)
  end

  # Parses a percentage such as "33,33" or "50 %" as basis points.
  def parse_basis_points(s : String) : Int64
    s = GoCompat.trim_space(GoCompat.trim_space(s).rchop("%"))
    begin
      parse_fixed(s, 2)
    rescue ValidationError
      raise ValidationError.new("Ungültige Prozentangabe „#{s}“.")
    end
  end

  # Parses an amount with the given number of decimal places and returns it
  # in the smallest unit. Both comma and dot are accepted as decimal
  # separator; thousands separators are recognized.
  def parse_minor(s : String, decimals : Int32) : Int64
    s = GoCompat.trim_space(GoCompat.trim_space(s).rchop("€"))
    raise ValidationError.new("Bitte einen Betrag eingeben.") if s.empty?
    parse_fixed(s, decimals)
  end

  private def parse_fixed(s : String, decimals : Int32) : Int64
    s = s.delete(' ').delete('\u{A0}') # not U+202F
    raise ValidationError.new("Bitte einen Betrag eingeben.") if s.empty?
    number = split_number(s, decimals < 3)
    raise ValidationError.new("Ungültiger Betrag „#{s}“.") unless number
    neg, int_part, frac = number
    # Superfluous zeros are fine: "1200,00" is 1200 yen (e.g. after
    # switching the currency of an amount from EUR to JPY).
    while frac.size > decimals && frac.ends_with?('0')
      frac = frac.rchop
    end
    if frac.size > decimals
      raise ValidationError.new("Dieser Betrag darf keine Nachkommastellen haben.") if decimals == 0
      raise ValidationError.new("Höchstens #{decimals} Nachkommastellen erlaubt.")
    end
    raise ValidationError.new("Der Betrag ist zu groß.") if int_part.size > 15
    v = GoCompat.parse_int(int_part + frac + "0" * (decimals - frac.size))
    raise ValidationError.new("Ungültiger Betrag „#{s}“.") unless v
    neg ? -v : v
  end

  # Splits a number with comma or dot as decimal separator and optional
  # thousands separators into sign, integer digits and fraction digits
  # (without separators; the integer part is at least "0"); nil if s is not
  # such a number. If both separators occur, the last one is the decimal
  # separator; repeated occurrences of the same kind are thousands
  # separators. A single dot before exactly three digits counts as a
  # thousands separator if dot_thousands is set ("17.000" = 17000), unless the
  # digits before it are only zeros: then it is a decimal point ("0.856" =
  # 0,856), since no number starts with a zero thousands group.
  private def split_number(s : String, dot_thousands : Bool) : {Bool, String, String}?
    return if s.empty?
    neg = s.starts_with?('-')
    s = s[1..] if neg || s.starts_with?('+')
    return if s.empty?
    return unless s.each_char.all? { |c| c.ascii_number? || c == '.' || c == ',' }

    int_part, frac = s, ""
    last_dot, last_comma = s.rindex('.') || -1, s.rindex(',') || -1
    dots, commas = s.count('.'), s.count(',')
    thousands = nil
    if dots > 0 && commas > 0
      dec = Math.max(last_dot, last_comma)
      if s[dec] == '.'
        thousands = ','
        return if dots > 1
      else
        thousands = '.'
        return if commas > 1
      end
      int_part, frac = s[0, dec], s[dec + 1..]
    elsif dots + commas > 1
      # Only one kind of separator, repeated: thousands separators.
      thousands = commas > 0 ? ',' : '.'
    elsif dots + commas == 1
      pos = Math.max(last_dot, last_comma)
      after = s.size - pos - 1
      if s[pos] == '.' && after == 3 && dot_thousands && !s[0, pos].strip('0').empty?
        thousands = '.'
      else
        int_part, frac = s[0, pos], s[pos + 1..]
        return if frac.empty?
      end
    end
    return if frac.includes?('.') || frac.includes?(',')
    if thousands
      groups = int_part.split(thousands)
      return if groups[0].empty? || groups[0].size > 3
      return unless groups.skip(1).all? { |g| g.size == 3 }
      int_part = groups.join
    end
    return if int_part.includes?('.') || int_part.includes?(',')
    int_part = "0" if int_part.empty?
    {neg, int_part, frac}
  end

  # Parses an exchange rate (units of the currency per 1 €) such as "1,0857",
  # "1.0857", "17000", "17.000,5" or "17,000.5". Separators work as for
  # amounts (`parse_minor`): a single dot before exactly three digits is a
  # thousands separator ("17.000" = 17000, "1.085" = 1085), except after a
  # leading zero ("0.856" = 0,856); otherwise decimals must be given with a
  # comma or with more/fewer than three digits. Rates ≤ 0 are invalid.
  def parse_rate(s : String) : Float64
    s = GoCompat.trim_space(s).delete(' ').delete('\u{A0}')
    bad = ValidationError.new("Ungültiger Wechselkurs „#{s}“ – bitte eine Zahl größer als 0 angeben (Einheiten der Währung pro 1 €).")
    number = split_number(s, true)
    raise bad unless number
    neg, int_part, frac = number
    raise bad if neg || int_part.size > 12 || frac.size > 12
    v = GoCompat.parse_float(int_part + "." + frac + "0")
    raise bad unless v && v > 0 && !v.infinite?
    v
  end

  # Formats v with the given number of decimals, a comma as decimal separator
  # and optionally dots as thousands separators.
  private def format_fixed(v : Int64, decimals : Int32, group : Bool) : String
    format_sep(v, decimals, ',', group)
  end

  # Formats v (in units of 10^-decimals) without thousands separators and with
  # sep as decimal separator: (123456, 2, ',') → "1234,56",
  # (-5, 2, '.') → "-0.05", (7, 0, '.') → "7".
  def format_decimal(v : Int64, decimals : Int32, sep : Char) : String
    format_sep(v, decimals, sep, false)
  end

  # Formats an amount in the currency's smallest unit for an input field:
  # (123456, "USD") → "1234,56", (500, "JPY") → "500".
  def format_minor_input(minor : Int64, currency : String) : String
    format_decimal(minor, currency_decimals(currency), ',')
  end

  # Formats an exchange rate with a comma as decimal separator and without
  # superfluous zeros: 1.0876 → "1,0876". Rates <= 0 (and NaN) yield "".
  def format_rate(rate : Float64) : String
    return "" unless rate > 0
    GoCompat.format_float(rate).sub('.', ',')
  end

  # Formats v with the given number of decimals and sep as decimal separator;
  # with group, thousands are separated by dots.
  private def format_sep(v : Int64, decimals : Int32, sep : Char, group : Bool) : String
    neg = v < 0
    u = neg ? 0_u64 &- v.to_u64! : v.to_u64 # Int64::MIN-safe
    s = u.to_s
    s = "0" * (decimals - s.size + 1) + s if s.size <= decimals
    int_part, frac = s[0, s.size - decimals], s[s.size - decimals..]
    if group && int_part.size > 3
      first = int_part.size % 3
      groups = first > 0 ? [int_part[0, first]] : [] of String
      first.step(to: int_part.size - 1, by: 3) { |i| groups << int_part[i, 3] }
      int_part = groups.join('.')
    end
    str = decimals > 0 ? "#{int_part}#{sep}#{frac}" : int_part
    neg ? "-" + str : str
  end

  # Reports whether s is a three-letter upper-case code (ISO 4217 format;
  # whether the currency exists is not checked).
  def valid_currency_code?(s : String) : Bool
    s.bytesize == 3 && s.each_byte.all? { |b| 'A'.ord <= b <= 'Z'.ord }
  end

  # Reports whether currency means euros, i.e. no foreign currency: "" or
  # "EUR" (case and surrounding spaces ignored).
  def eur?(currency : String) : Bool
    GoCompat.to_upper(GoCompat.trim_space(currency)).in?("", "EUR")
  end

  # Returns the number of decimal places of a currency (ISO 4217). Unknown
  # currencies have 2.
  def currency_decimals(currency : String) : Int32
    case GoCompat.to_upper(currency)
    when "JPY", "KRW", "ISK", "HUF", "CLP", "VND", "XAF", "XOF", "PYG", "UGX", "IDR"
      0
    when "KWD", "BHD", "OMR", "JOD", "TND", "LYD", "IQD"
      3
    else
      2
    end
  end

  # Converts a foreign-currency amount (smallest unit) to euro cents. rate is
  # given in ECB format: units of foreign currency per 1 EUR. Rounds half away
  # from zero. For an invalid rate (<= 0, NaN, infinite) the result is 0.
  def to_eur_cents(minor : Int64, currency : String, rate : Float64) : Int64
    return 0_i64 if rate <= 0 || rate.nan? || rate.infinite?
    scale = 10.0 ** currency_decimals(currency)
    eur = (minor.to_f / scale / rate * 100).round(:ties_away)
    # Go's int64(float) yields MinInt64 for values out of range (amd64).
    -9.223372036854775808e18 <= eur < 9.223372036854775808e18 ? eur.to_i64 : Int64::MIN
  end
end
