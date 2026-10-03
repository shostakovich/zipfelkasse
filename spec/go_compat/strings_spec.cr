require "../spec_helper"

# Expected values were produced by Go 1.26.5 (the toolchain of go.mod).
# Additionally, `print?`, `lower`, `upper` and `equal_fold` were compared
# with Go for every code point once during the port (Crystal 1.21 knows
# Unicode 17, Go 1.26 Unicode 15; re-check when either is upgraded).
private alias G = Zipfelkasse::GoCompat

describe Zipfelkasse::GoCompat do
  describe ".space?" do
    it "matches unicode.IsSpace" do
      [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000, 0x2005, 0x200A,
       0x2028, 0x2029, 0x202F, 0x205F, 0x3000].each { |r| G.space?(r.chr).should be_true }
      [0x00, 0x08, 0x0E, 0x1C, 0x41, 0xAD, 0x180E, 0x200B, 0x2060, 0xFEFF, 0xFFFD].each { |r| G.space?(r.chr).should be_false }
    end
  end

  describe ".fields and .trim_space" do
    it "match strings.Fields and strings.TrimSpace" do
      {
        ""                                                    => {[] of String, ""},
        "  "                                                  => {[] of String, ""},
        " a  b "                                              => {["a", "b"], "a  b"},
        "a\u{85}b\u{a0}c\u{2000}d\u{3000}e\u{202f}f\u{200b}g" => {["a", "b", "c", "d", "e", "f\u{200b}g"], "a\u{85}b\u{a0}c\u{2000}d\u{3000}e\u{202f}f\u{200b}g"},
        "\t\n\v\f\r x \r\n"                                   => {["x"], "x"},
        "\u{feff}a"                                           => {["\u{feff}a"], "\u{feff}a"},
        "a\xffb c"                                            => {["a\xffb", "c"], "a\xffb c"},
        "\u{85}\u{85}"                                        => {[] of String, ""},
        "\u{85} x\u{a0}"                                      => {["x"], "x"},
      }.each do |input, (fields, trimmed)|
        G.fields(input).should eq fields
        G.trim_space(input).should eq trimmed
      end
    end

    it "keeps invalid bytes as they are" do
      G.trim_space(" \xff ").to_slice.should eq Bytes[0xff]
    end
  end

  describe ".to_lower and .to_upper" do
    it "map rune by rune like strings.ToLower / strings.ToUpper" do
      {
        "ABC"       => {"abc", "ABC"},
        "ÄÖÜ"       => {"äöü", "ÄÖÜ"},
        "İSTANBUL"  => {"istanbul", "İSTANBUL"},
        "ẞ"         => {"ß", "ẞ"},
        "ΣΑΣ"       => {"σασ", "ΣΑΣ"},
        "ǅ"         => {"ǆ", "Ǆ"},
        "Ǆ"         => {"ǆ", "Ǆ"},
        "ß"         => {"ß", "ß"},
        "Kelvin K"  => {"kelvin k", "KELVIN K"},
        "\u{212a}"  => {"k", "\u{212a}"},
        "a\xffB"    => {"a\u{fffd}b", "A\u{fffd}B"},
        "ＡＢＣ"       => {"ａｂｃ", "ＡＢＣ"},
        "\u{a7db}"  => {"\u{a7db}", "\u{a7db}"},
        "\u{10d50}" => {"\u{10d50}", "\u{10d50}"},
        "ƛ"         => {"ƛ", "ƛ"},
      }.each do |input, (lower, upper)|
        G.to_lower(input).should eq lower
        G.to_upper(input).should eq upper
      end
    end

    it "ignores mappings of characters newer than Go's Unicode 15.0" do
      G.lower('\u{a7dc}').should eq '\u{a7dc}' # Unicode 16: uppercase of ƛ
      G.upper('ƛ').should eq 'ƛ'
      G.upper('\u{1f88}').should eq '\u{1f88}' # title case stays (as in Go)
      G.lower('\u{1f88}').should eq '\u{1f80}'
    end
  end

  describe ".equal_fold" do
    it "uses Unicode simple case folding like strings.EqualFold" do
      {
        {"Go", "GO"}                     => true,
        {"ß", "ss"}                      => false,
        {"ß", "ẞ"}                       => true,
        {"K", "k"}                       => true,
        {"\u{212a}", "k"}                => true,
        {"\u{212a}", "K"}                => true,
        {"ǅ", "ǆ"}                       => true,
        {"ǅ", "Ǆ"}                       => true,
        {"İ", "i"}                       => false,
        {"ı", "I"}                       => false,
        {"σ", "ς"}                       => true,
        {"Σ", "ς"}                       => true,
        {"ᾈ", "ᾀ"}                       => true,
        {"\xff", "\xfe"}                 => true,
        {"a", "ab"}                      => false,
        {"", ""}                         => true,
        {"Sonstiges", "SONSTIGES"}       => true,
        {"µ", "μ"}                       => true,
        {"µ", "Μ"}                       => true,
        {"ſ", "S"}                       => true,
        {"Å", "å"}                       => true,
        {"\u{212b}", "å"}                => true,
        {"\u{10d50}", "\u{10d70}"}       => false, # Unicode 16, unknown to Go
        {"straße", "STRASSE"}            => false,
        {"Lebensmittel", "lebensmittel"} => true,
      }.each do |(a, b), want|
        G.equal_fold(a, b).should eq want
        G.equal_fold(b, a).should eq want
      end
    end
  end

  describe ".print?" do
    it "matches strconv.IsPrint" do
      ['a', ' ', 'ä', '€', '\u{300}', '\u{fffd}', '😀', '日'].each { |c| G.print?(c).should be_true }
      ['\u{0}', '\u{7f}', '\u{85}', '\u{a0}', '\u{ad}', '\u{378}', '\u{2028}', '\u{feff}', '\u{e0001}',
       '\u{f0000}', '\u{10d50}', '\u{10ffff}'].each { |c| G.print?(c).should be_false }
    end
  end

  describe ".quote" do
    it "quotes like strconv.Quote" do
      {
        ""                                         => %q(""),
        "abc"                                      => %q("abc"),
        "a\"b"                                     => %q("a\"b"),
        "a\\b"                                     => %q("a\\b"),
        "\a\b\f\n\r\t\v"                           => %q("\a\b\f\n\r\t\v"),
        "\u{0}\u{1}\u{1f}\u{7f}"                   => %q("\x00\x01\x1f\x7f"),
        "äöü ß €"                                  => %q("äöü ß €"),
        "\u{a0}\u{ad}\u{85}"                       => "\"\\u00a0\\u00ad\\u0085\"",
        "\u{2028}\u{2029}\u{202f}\u{200b}\u{feff}" => "\"\\u2028\\u2029\\u202f\\u200b\\ufeff\"",
        "\xff"                                     => %q("\xff"),
        "a\xe2\x82b"                               => %q("a\xe2\x82b"),
        "😀"                                        => %q("😀"),
        "\u{e0001}"                                => %q("\U000e0001"),
        "\u{10ffff}"                               => %q("\U0010ffff"),
        "\u{fffd}"                                 => "\"\u{fffd}\"",
        "\u{378}"                                  => "\"\\u0378\"",
        "\u{10d50}"                                => %q("\U00010d50"),
        "日本語"                                      => %q("日本語"),
        "\u{300}"                                  => "\"\u{300}\"",
        "'`$x{}"                                   => %q("'`$x{}"),
        "\u{1680}\u{3000}"                         => "\"\\u1680\\u3000\"",
        "\u{f0000}"                                => %q("\U000f0000"),
      }.each do |input, want|
        G.quote(input).should eq want
      end
    end
  end
end
