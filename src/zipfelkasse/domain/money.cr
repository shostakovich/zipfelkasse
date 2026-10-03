# Pure business logic: no IO, no dependencies.
module Zipfelkasse::Domain
  extend self

  # Amounts are Int64 in the smallest unit everywhere (cents for EUR).

  # Caps amounts so that multiplications during splitting cannot overflow
  # (10 billion €).
  MAX_AMOUNT_CENTS = 1_000_000_000_000_i64

  # The German message is shown to the user directly in the form.
  class ValidationError < Exception
    getter msg : String

    def initialize(@msg : String)
      super(@msg)
    end
  end

  def format_cents(c : Int64) : String
    format_fixed(c, 2, true) + " €"
  end

  def format_cents_input(c : Int64) : String
    format_fixed(c, 2, false)
  end

  def format_money(minor : Int64, currency : String) : String
    return format_cents(minor) if eur?(currency)
    currency = currency.strip.upcase
    format_fixed(minor, currency_decimals(currency), true) + " " + currency
  end

  def format_basis_points(bp : Int64) : String
    format_fixed(bp, 2, false) + " %"
  end

  def parse_cents(s : String) : Int64
    parse_minor(s, 2)
  end

  def parse_basis_points(s : String) : Int64
    s = s.strip.rchop("%").strip
    begin
      parse_fixed(s, 2)
    rescue ValidationError
      raise ValidationError.new("Ungültige Prozentangabe „#{s}“.")
    end
  end

  def parse_minor(s : String, decimals : Int32) : Int64
    s = s.strip.rchop("€").strip
    raise ValidationError.new("Bitte einen Betrag eingeben.") if s.empty?
    parse_fixed(s, decimals)
  end

  private def parse_fixed(s : String, decimals : Int32) : Int64
    s = s.gsub(' ', "").gsub('\u{A0}', "") # only space and NBSP, not U+202F
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
    v = (int_part + frac + "0" * (decimals - frac.size)).to_i64?
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

  # Exchange rate in units of the currency per 1 €; separators as in split_number.
  def parse_rate(s : String) : Float64
    s = s.strip.gsub(' ', "").gsub('\u{A0}', "")
    bad = ValidationError.new("Ungültiger Wechselkurs „#{s}“ – bitte eine Zahl größer als 0 angeben (Einheiten der Währung pro 1 €).")
    number = split_number(s, true)
    raise bad unless number
    neg, int_part, frac = number
    raise bad if neg || int_part.size > 12 || frac.size > 12
    v = (int_part + "." + frac + "0").to_f?
    raise bad unless v && v > 0 && !v.infinite?
    v
  end

  private def format_fixed(v : Int64, decimals : Int32, group : Bool) : String
    format_sep(v, decimals, ',', group)
  end

  def format_decimal(v : Int64, decimals : Int32, sep : Char) : String
    format_sep(v, decimals, sep, false)
  end

  def format_minor_input(minor : Int64, currency : String) : String
    format_decimal(minor, currency_decimals(currency), ',')
  end

  def format_rate(rate : Float64) : String
    return "" unless rate > 0 && rate.finite?
    plain_decimal(rate).sub('.', ',')
  end

  # Shortest digits that read back as v, without exponent: 1.0e-7 → "0.0000001".
  private def plain_decimal(v : Float64) : String
    mantissa, _, exp = v.to_s.partition('e')
    int_part, _, frac = mantissa.partition('.')
    frac = "" if frac == "0"
    digits = int_part + frac
    point = int_part.size + (exp.empty? ? 0 : exp.to_i)
    if point <= 0
      "0." + "0" * -point + digits
    elsif point >= digits.size
      digits + "0" * (point - digits.size)
    else
      "#{digits[0, point]}.#{digits[point..]}"
    end
  end

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

  # Format only; whether the currency exists is not checked.
  def valid_currency_code?(s : String) : Bool
    s.bytesize == 3 && s.each_byte.all? { |b| 'A'.ord <= b <= 'Z'.ord }
  end

  def eur?(currency : String) : Bool
    currency.strip.upcase.in?("", "EUR")
  end

  def currency_decimals(currency : String) : Int32
    case currency.upcase
    when "JPY", "KRW", "ISK", "HUF", "CLP", "VND", "XAF", "XOF", "PYG", "UGX", "IDR"
      0
    when "KWD", "BHD", "OMR", "JOD", "TND", "LYD", "IQD"
      3
    else
      2
    end
  end

  # rate is in ECB format: units of foreign currency per 1 EUR.
  def to_eur_cents(minor : Int64, currency : String, rate : Float64) : Int64
    return 0_i64 if rate <= 0 || rate.nan? || rate.infinite?
    scale = 10.0 ** currency_decimals(currency)
    eur = (minor.to_f / scale / rate * 100).round(:ties_away)
    -9.223372036854775808e18 <= eur < 9.223372036854775808e18 ? eur.to_i64 : Int64::MIN
  end
end
