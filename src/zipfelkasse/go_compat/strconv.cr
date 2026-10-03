# Go's number conversions where Crystal's stdlib behaves differently.
#
# Go name                             → Crystal name
# strconv.FormatFloat(f, 'f', -1, 64) → GoCompat.format_float
# encoding/json float64 encoding      → GoCompat.json_float
# strconv.ParseFloat(s, 64)           → GoCompat.parse_float (nil on error)
# strconv.ParseInt(s, 10, 64)         → GoCompat.parse_int (nil on error)
module Zipfelkasse::GoCompat
  extend self

  # `strconv.FormatFloat(f, 'f', -1, 64)`: the shortest decimal that rounds
  # back to f, never with an exponent and without a trailing ".0":
  # 1.0 → "1", 1e21 → "1000000000000000000000", 1e-7 → "0.0000001".
  # NaN → "NaN", infinities → "+Inf" / "-Inf", -0.0 → "-0".
  def format_float(f : Float64) : String
    return "NaN" if f.nan?
    return f > 0 ? "+Inf" : "-Inf" if f.infinite?
    neg, digits, point = shortest_decimal(f)
    s = if digits.empty?
          "0"
        elsif point <= 0
          "0." + "0" * -point + digits
        elsif point >= digits.size
          digits + "0" * (point - digits.size)
        else
          digits[0, point] + "." + digits[point..]
        end
    neg ? "-" + s : s
  end

  # A float64 as Go's `encoding/json` writes it: like `format_float` for
  # 1e-6 <= |f| < 1e21 (and 0), otherwise in exponent form without exponent
  # padding ("1e+21", "1.5e-7", "5e-324"). NaN and infinities are not
  # representable in JSON (Go fails with an UnsupportedValueError).
  def json_float(f : Float64) : String
    raise ArgumentError.new("json: unsupported value: #{format_float(f)}") if f.nan? || f.infinite?
    abs = f.abs
    return format_float(f) if abs == 0 || (1e-6 <= abs < 1e21)
    neg, digits, point = shortest_decimal(f)
    exp = point - 1
    String.build do |io|
      io << '-' if neg
      io << digits[0]
      io << '.' << digits[1..] if digits.size > 1
      io << 'e' << (exp < 0 ? '-' : '+') << exp.abs
    end
  end

  # `strconv.ParseFloat(s, 64)`: accepts exactly what Go accepts (sign,
  # decimal and hexadecimal (`0x1p-2`) mantissas, exponents, `_` between
  # digits, "Inf"/"Infinity"/"NaN" in any case; no surrounding spaces). Returns
  # nil where Go returns an error, including overflow to ±Inf; underflow
  # gives 0 like Go.
  def parse_float(s : String) : Float64?
    return unless s.ascii_only?
    lower = s.downcase
    return Float64::NAN if lower == "nan"
    if unsigned(lower).in?("inf", "infinity")
      return lower.starts_with?('-') ? -Float64::INFINITY : Float64::INFINITY
    end
    return unless go_float_syntax?(lower)
    # The syntax is checked; the C library converts with correct rounding
    # (also hexadecimal mantissas).
    v = LibC.strtod(lower.delete('_'), nil)
    v.infinite? ? nil : v
  end

  # `strconv.ParseInt(s, 10, 64)`: optional sign and ASCII digits only (no
  # spaces, no underscores); nil on syntax errors and overflow.
  def parse_int(s : String) : Int64?
    s.to_i64?(whitespace: false) if s.matches?(/\A[+-]?[0-9]+\z/)
  end

  # Sign, significant digits (without leading/trailing zeros, "" for 0) and
  # decimal point position of the shortest round-trip representation of f:
  # |f| = 0.DIGITS × 10^point. Crystal's `Float#to_s` and Go's FormatFloat
  # both produce the shortest round-trip digits.
  private def shortest_decimal(f : Float64) : {Bool, String, Int32}
    s = f.to_s
    mantissa, _, exp = unsigned(s).partition('e')
    int, _, frac = mantissa.partition('.')
    digits = int + frac
    stripped = digits.lstrip('0')
    point = int.size + (exp.to_i? || 0) - (digits.size - stripped.size)
    {s.starts_with?('-'), stripped.rstrip('0'), point}
  end

  private def unsigned(s : String) : String
    s.starts_with?('+') || s.starts_with?('-') ? s[1..] : s
  end

  # Go's `readFloat` + `underscoreOK` as a pure syntax check of a whole
  # (ASCII, lower-case) string; special values are handled before.
  private def go_float_syntax?(s : String) : Bool
    s = unsigned(s)
    hex = s.size > 2 && s.starts_with?("0x")
    i = hex ? 2 : 0
    underscores = sawdot = sawdigits = false
    while c = s[i]?
      if c == '_'
        underscores = true
      elsif c == '.'
        break if sawdot
        sawdot = true
      elsif c.ascii_number? || (hex && c.in?('a'..'f'))
        sawdigits = true
      else
        break
      end
      i += 1
    end
    return false unless sawdigits
    if s[i]? == (hex ? 'p' : 'e')
      i += 1
      i += 1 if s[i]?.in?('+', '-')
      return false unless s[i]?.try(&.ascii_number?)
      while (c = s[i]?) && (c.ascii_number? || c == '_')
        underscores = true if c == '_'
        i += 1
      end
    elsif hex
      return false # a hexadecimal mantissa requires a 'p' exponent
    end
    i == s.size && (!underscores || underscores_ok?(s))
  end

  # Go's `underscoreOK` for an unsigned number: underscores only between
  # digits, or between a base prefix and a digit.
  private def underscores_ok?(s : String) : Bool
    prefix = s.size >= 2 && s[0] == '0' && s[1].in?('b', 'o', 'x')
    hex = prefix && s[1] == 'x'
    saw = prefix ? '0' : '^'
    s.each_char.skip(prefix ? 2 : 0).each do |c|
      if c.ascii_number? || (hex && c.in?('a'..'f'))
        saw = '0'
      elsif c == '_'
        return false unless saw == '0'
        saw = '_'
      else
        return false if saw == '_'
        saw = '!'
      end
    end
    saw != '_'
  end
end
