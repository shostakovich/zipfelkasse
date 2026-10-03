# Go's string functions where Crystal's stdlib behaves differently.
#
# Go name                          → Crystal name
# unicode.IsSpace                  → GoCompat.space?
# strconv.IsPrint                  → GoCompat.print?
# unicode.ToLower / ToUpper (rune) → GoCompat.lower / GoCompat.upper
# strings.ToLower / ToUpper        → GoCompat.to_lower / GoCompat.to_upper
# strings.Fields                   → GoCompat.fields
# strings.TrimSpace                → GoCompat.trim_space
# strings.EqualFold                → GoCompat.equal_fold
# strconv.Quote, fmt's %q          → GoCompat.quote
#
# Invalid UTF-8 is handled like Go: every invalid byte is one U+FFFD rune,
# which is never a space and never printable.
module Zipfelkasse::GoCompat
  extend self

  # Go's `unicode.IsSpace`: '\t', '\n', '\v', '\f', '\r', ' ', U+0085 (NEL),
  # U+00A0 (NBSP) and the other Unicode White_Space characters. Unlike
  # `Char#whitespace?` it includes U+0085.
  def space?(c : Char) : Bool
    case c.ord
    when 0x09..0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000..0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000
      true
    else
      false
    end
  end

  # Go's `strconv.IsPrint` (= `unicode.IsPrint`): letters, marks, numbers,
  # punctuation, symbols and the ASCII space, as of Go's Unicode version
  # (15.0.0). Other spaces such as U+00A0 are not printable.
  def print?(c : Char) : Bool
    r = c.ord
    return (0x20 <= r <= 0x7E) || (0xA1 <= r <= 0xFF && r != 0xAD) if r <= 0xFF
    i = (0...PRINT_RANGES.size // 2).bsearch { |k| PRINT_RANGES[2 * k + 1] >= r }
    !i.nil? && PRINT_RANGES[2 * i] <= r
  end

  # Go's `unicode.ToLower` (simple per-rune mapping, `İ` → `i`). Crystal knows
  # a newer Unicode version than Go; mappings involving characters Go does
  # not know yet are left alone.
  def lower(c : Char) : Char
    return c.downcase if c.ascii?
    known_mapping(c, c.downcase)
  end

  # Go's `unicode.ToUpper` (simple per-rune mapping, `ß` stays `ß`).
  def upper(c : Char) : Char
    return c.upcase if c.ascii?
    case c.ord
    when 0x01C5, 0x01C8, 0x01CB, 0x01F2 # title-case digraphs (ǅ → Ǆ); Crystal keeps them
      c - 1
    else
      known_mapping(c, c.upcase)
    end
  end

  # Go's `strings.ToLower`: maps rune by rune with `lower`.
  def to_lower(s : String) : String
    return s.downcase if s.ascii_only?
    String.build(s.bytesize) { |io| s.each_char { |c| io << lower(c) } }
  end

  # Go's `strings.ToUpper`: maps rune by rune with `upper`.
  def to_upper(s : String) : String
    return s.upcase if s.ascii_only?
    String.build(s.bytesize) { |io| s.each_char { |c| io << upper(c) } }
  end

  # Go's `strings.Fields`: splits s around runs of `space?` characters.
  def fields(s : String) : Array(String)
    result = [] of String
    start = -1
    reader = Char::Reader.new(s)
    while reader.has_next?
      if space?(reader.current_char)
        result << s.byte_slice(start, reader.pos - start) if start >= 0
        start = -1
      elsif start < 0
        start = reader.pos
      end
      reader.next_char
    end
    result << s.byte_slice(start) if start >= 0
    result
  end

  # Go's `strings.TrimSpace`: removes leading and trailing `space?` characters.
  def trim_space(s : String) : String
    start = -1
    stop = 0
    reader = Char::Reader.new(s)
    while reader.has_next?
      unless space?(reader.current_char)
        start = reader.pos if start < 0
        stop = reader.pos + reader.current_char_width
      end
      reader.next_char
    end
    start < 0 ? "" : s.byte_slice(start, stop - start)
  end

  # Go's `strings.EqualFold`: equality under Unicode simple case folding
  # (`ẞ` equals `ß` and `K` (Kelvin) equals `k`, but `ß` does not equal `ss`).
  def equal_fold(a : String, b : String) : Bool
    a.size == b.size && a.each_char.zip(b.each_char).all? { |x, y| x == y || fold_key(x) == fold_key(y) }
  end

  # Go's `strconv.Quote` (and `fmt`'s `%q`): double-quoted, with `"` and `\`
  # escaped, printable runes (`print?`) kept, `\a \b \f \n \r \t \v`, `\xNN` for
  # other control characters and invalid bytes, `\uNNNN` / `\UNNNNNNNN` for
  # other non-printable runes.
  def quote(s : String) : String
    String.build(s.bytesize + 2) do |io|
      io << '"'
      reader = Char::Reader.new(s)
      while reader.has_next?
        c = reader.current_char
        if byte = reader.error
          io << "\\x" << byte.to_s(16).rjust(2, '0')
        elsif c == '"' || c == '\\'
          io << '\\' << c
        elsif print?(c)
          io << c
        else
          case r = c.ord
          when 0x07 then io << "\\a"
          when 0x08 then io << "\\b"
          when 0x0C then io << "\\f"
          when 0x0A then io << "\\n"
          when 0x0D then io << "\\r"
          when 0x09 then io << "\\t"
          when 0x0B then io << "\\v"
          when 0x00...0x20, 0x7F
            io << "\\x" << r.to_s(16).rjust(2, '0')
          when .< 0x10000
            io << "\\u" << r.to_s(16).rjust(4, '0')
          else
            io << "\\U" << r.to_s(16).rjust(8, '0')
          end
        end
        reader.next_char
      end
      io << '"'
    end
  end

  # The case mapping c → mapped, unless one of them is unknown to Go's
  # Unicode version (case letters are always printable when assigned).
  private def known_mapping(c : Char, mapped : Char) : Char
    mapped != c && print?(c) && print?(mapped) ? mapped : c
  end

  # A representative of c's case-folding orbit as Go's `unicode.SimpleFold`
  # defines it: two runes are equal under folding iff their keys are equal.
  private def fold_key(c : Char) : Char
    return c.downcase if c.ascii?
    case c.ord
    when 0x1E9E # ẞ folds to ß (Crystal only knows the full folding to "ss")
      'ß'
    when 0x1F88..0x1F8F, 0x1F98..0x1F9F, 0x1FA8..0x1FAF # Greek title case with ypogegrammeni
      c - 8
    when 0x1FBC, 0x1FCC, 0x1FFC
      c - 9
    else
      known_mapping(c, c.downcase(Unicode::CaseOptions::Fold))
    end
  end
end
