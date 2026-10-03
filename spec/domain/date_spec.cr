require "../spec_helper"

private alias D = Zipfelkasse::Domain

private def d(s : String) : Time
  Time.parse_utc(s, D::DATE_LAYOUT)
end

private def validation_error(&) : String
  yield
  fail "expected a ValidationError"
rescue e : Zipfelkasse::Domain::ValidationError
  e.msg
end

describe Zipfelkasse::Domain do
  describe ".next_date" do
    {
      {"weekly", D::Frequency::Weekly, "2026-01-05", "2026-01-05", "2026-01-12"},
      {"weekly across year boundary", D::Frequency::Weekly, "2025-12-29", "2025-12-30", "2026-01-05"},
      {"weekly before anchor", D::Frequency::Weekly, "2026-03-01", "2026-01-01", "2026-03-01"},
      {"monthly simple", D::Frequency::Monthly, "2026-01-15", "2026-01-15", "2026-02-15"},
      {"monthly Jan 31 → Feb 28", D::Frequency::Monthly, "2026-01-31", "2026-01-31", "2026-02-28"},
      {"monthly Jan 31 → Feb 29 leap year", D::Frequency::Monthly, "2028-01-31", "2028-01-31", "2028-02-29"},
      {"monthly back to anchor after February", D::Frequency::Monthly, "2026-01-31", "2026-02-28", "2026-03-31"},
      {"monthly April 30", D::Frequency::Monthly, "2026-01-31", "2026-03-31", "2026-04-30"},
      {"monthly December → January", D::Frequency::Monthly, "2026-12-31", "2026-12-31", "2027-01-31"},
      {"monthly mid-period", D::Frequency::Monthly, "2026-01-10", "2026-05-20", "2026-06-10"},
      {"monthly before anchor", D::Frequency::Monthly, "2026-05-10", "2026-01-01", "2026-05-10"},
      {"yearly", D::Frequency::Yearly, "2026-03-15", "2026-03-15", "2027-03-15"},
      {"yearly Feb 29", D::Frequency::Yearly, "2028-02-29", "2028-02-29", "2029-02-28"},
      {"yearly Feb 29 back in leap year", D::Frequency::Yearly, "2028-02-29", "2031-03-01", "2032-02-29"},
    }.each do |(name, freq, anchor, after, want)|
      it name do
        D.next_date(freq, d(anchor), d(after)).to_s(D::DATE_LAYOUT).should eq want
      end
    end

    it "takes the calendar date in the given zone" do
      berlin = Time::Location.load("Europe/Berlin")
      D.next_date(D::Frequency::Weekly, Time.local(2026, 3, 28, 23, 30, location: berlin), Time.utc(2026, 3, 29, 1, 0)).should eq Time.utc(2026, 4, 4)
    end
  end

  it "computes occurrences from the anchor" do
    anchor = d("2026-01-31")
    ["2026-01-31", "2026-02-28", "2026-03-31", "2026-04-30", "2026-05-31"].each_with_index do |want, n|
      D.occurrence(D::Frequency::Monthly, anchor, n).to_s(D::DATE_LAYOUT).should eq want
    end
  end

  it "computes occurrences for negative and large n" do
    anchor = d("2026-01-31")
    {
       -1 => {"2025-12-31", "2025-01-31", "2026-01-24"},
       -2 => {"2025-11-30", "2024-01-31", "2026-01-17"},
      -13 => {"2024-12-31", "2013-01-31", "2025-11-01"},
      -25 => {"2023-12-31", "2001-01-31", "2025-08-09"},
       13 => {"2027-02-28", "2039-01-31", "2026-05-02"},
       25 => {"2028-02-29", "2051-01-31", "2026-07-25"},
        0 => {"2026-01-31", "2026-01-31", "2026-01-31"},
    }.each do |n, (monthly, yearly, weekly)|
      D.occurrence(D::Frequency::Monthly, anchor, n).to_s(D::DATE_LAYOUT).should eq monthly
      D.occurrence(D::Frequency::Yearly, anchor, n).to_s(D::DATE_LAYOUT).should eq yearly
      D.occurrence(D::Frequency::Weekly, anchor, n).to_s(D::DATE_LAYOUT).should eq weekly
    end
  end

  it "names the frequencies by their keys" do
    D::Frequency.values.map(&.key).should eq %w(weekly monthly yearly)
    D::Frequency.from_key?("monthly").should eq D::Frequency::Monthly
    D::Frequency.from_key?("Monthly").should be_nil
    D::Frequency.from_key?("daily").should be_nil
  end

  it "parses dates" do
    {
      "2026-10-02"   => "2026-10-02",
      "02.10.2026"   => "2026-10-02",
      "2.10.2026"    => "2026-10-02",
      " 2026-10-02 " => "2026-10-02",
      ""             => nil,
      "2026-02-30"   => nil,
      "yesterday"    => nil,
      "2000-01-01"   => "2000-01-01",
      "2100-12-31"   => "2100-12-31",
      "1999-12-31"   => nil,
      "2101-01-01"   => nil,
      "0026-10-02"   => nil,
      "9999-12-31"   => nil,
    }.each do |input, want|
      if want
        got = D.parse_date(input)
        got.to_s(D::DATE_LAYOUT).should eq want
        got.location.should eq Time::Location::UTC
        got.hour.should eq 0
      else
        expect_raises(D::ValidationError) { D.parse_date(input) }
      end
    end
  end

  it "parses dates strictly" do
    {
      "+999-01-01"              => "Ungültiges Datum „+999-01-01“.",
      "0000-01-01"              => "Ungültiges Datum „0000-01-01“.",
      "2026-9-01"               => "Ungültiges Datum „2026-9-01“.",
      "02.1.2026"               => "2026-01-02",
      "2.01.2026"               => "2026-01-02",
      "2.1.26"                  => "Ungültiges Datum „2.1.26“.",
      "+2026-01-01"             => "Ungültiges Datum „+2026-01-01“.",
      "2028-02-29"              => "2028-02-29",
      "2027-02-29"              => "Ungültiges Datum „2027-02-29“.",
      "29.02.2028"              => "2028-02-29",
      "31.4.2026"               => "Ungültiges Datum „31.4.2026“.",
      "2026-00-10"              => "Ungültiges Datum „2026-00-10“.",
      "2026-13-01"              => "Ungültiges Datum „2026-13-01“.",
      "00.01.2026"              => "Ungültiges Datum „00.01.2026“.",
      "\t2026-10-02\u{a0}"      => "2026-10-02",
      "123.1.2026"              => "Ungültiges Datum „123.1.2026“.",
      "2026-10-02x"             => "Ungültiges Datum „2026-10-02x“.",
      "\u{ff11}\u{ff12}.1.2026" => "Ungültiges Datum „\u{ff11}\u{ff12}.1.2026“.",
      "\u{661}.1.2026"          => "Ungültiges Datum „\u{661}.1.2026“.",
      "2026–10–02"              => "Ungültiges Datum „2026–10–02“.",
      "2026-10-0\xff"           => "Ungültiges Datum „2026-10-0\xff“.",
      ""                        => "Bitte ein Datum angeben.",
      " \u{3000} "              => "Bitte ein Datum angeben.",
    }.each do |input, want|
      if want.starts_with?('2')
        D.parse_date(input).should eq d(want)
      else
        validation_error { D.parse_date(input) }.should eq want
      end
    end
  end

  it "formats dates" do
    D.format_date(d("2026-10-02")).should eq "02.10.2026"
    D.format_date(Time.utc(26, 10, 2)).should eq "02.10.0026"
  end

  it "takes today's date in a time zone" do
    berlin = Time::Location.load("Europe/Berlin")
    # 23:30 UTC on Oct 1 is already Oct 2 in Berlin.
    got = D.date_of(Time.utc(2026, 10, 1, 23, 30).in(berlin))
    got.to_s(D::DATE_LAYOUT).should eq "2026-10-02"
    got.location.should eq Time::Location::UTC
  end

  it "names the year range in the message" do
    message = validation_error { D.parse_date("0026-10-02") }
    message.should contain "2000"
    message.should contain "2100"
  end
end
