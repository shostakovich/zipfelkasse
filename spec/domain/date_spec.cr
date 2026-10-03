require "../spec_helper"

private def d(s : String) : Time
  Time.parse_utc(s, Domain::DATE_LAYOUT)
end

describe Domain do
  describe ".next_date" do
    {
      {"weekly", Domain::Frequency::Weekly, "2026-01-05", "2026-01-05", "2026-01-12"},
      {"weekly across year boundary", Domain::Frequency::Weekly, "2025-12-29", "2025-12-30", "2026-01-05"},
      {"weekly before anchor", Domain::Frequency::Weekly, "2026-03-01", "2026-01-01", "2026-03-01"},
      {"monthly simple", Domain::Frequency::Monthly, "2026-01-15", "2026-01-15", "2026-02-15"},
      {"monthly Jan 31 → Feb 28", Domain::Frequency::Monthly, "2026-01-31", "2026-01-31", "2026-02-28"},
      {"monthly Jan 31 → Feb 29 leap year", Domain::Frequency::Monthly, "2028-01-31", "2028-01-31", "2028-02-29"},
      {"monthly back to anchor after February", Domain::Frequency::Monthly, "2026-01-31", "2026-02-28", "2026-03-31"},
      {"monthly April 30", Domain::Frequency::Monthly, "2026-01-31", "2026-03-31", "2026-04-30"},
      {"monthly December → January", Domain::Frequency::Monthly, "2026-12-31", "2026-12-31", "2027-01-31"},
      {"monthly mid-period", Domain::Frequency::Monthly, "2026-01-10", "2026-05-20", "2026-06-10"},
      {"monthly before anchor", Domain::Frequency::Monthly, "2026-05-10", "2026-01-01", "2026-05-10"},
      {"yearly", Domain::Frequency::Yearly, "2026-03-15", "2026-03-15", "2027-03-15"},
      {"yearly Feb 29", Domain::Frequency::Yearly, "2028-02-29", "2028-02-29", "2029-02-28"},
      {"yearly Feb 29 back in leap year", Domain::Frequency::Yearly, "2028-02-29", "2031-03-01", "2032-02-29"},
    }.each do |(name, freq, anchor, after, want)|
      it name do
        Domain.next_date(freq, d(anchor), d(after)).to_s(Domain::DATE_LAYOUT).should eq want
      end
    end

    it "takes the calendar date in the given zone" do
      berlin = Time::Location.load("Europe/Berlin")
      Domain.next_date(Domain::Frequency::Weekly, Time.local(2026, 3, 28, 23, 30, location: berlin), Time.utc(2026, 3, 29, 1, 0)).should eq Time.utc(2026, 4, 4)
    end
  end

  it "computes monthly occurrences from the anchor day" do
    anchor = d("2026-01-31")
    ["2026-01-31", "2026-02-28", "2026-03-31", "2026-04-30", "2026-05-31"].each_with_index do |want, n|
      Domain.occurrence(Domain::Frequency::Monthly, anchor, n).to_s(Domain::DATE_LAYOUT).should eq want
    end
  end

  it "computes occurrences before the anchor and far behind it" do
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
      Domain.occurrence(Domain::Frequency::Monthly, anchor, n).to_s(Domain::DATE_LAYOUT).should eq monthly
      Domain.occurrence(Domain::Frequency::Yearly, anchor, n).to_s(Domain::DATE_LAYOUT).should eq yearly
      Domain.occurrence(Domain::Frequency::Weekly, anchor, n).to_s(Domain::DATE_LAYOUT).should eq weekly
    end
  end

  it "names the frequencies by their stored keys" do
    Domain::Frequency.values.map(&.key).should eq %w(weekly monthly yearly)
    Domain::Frequency.from_key?("monthly").should eq Domain::Frequency::Monthly
    Domain::Frequency.from_key?("Monthly").should be_nil
    Domain::Frequency.from_key?("daily").should be_nil
  end

  describe ".parse_date" do
    {
      "2026-10-02" => "2026-10-02", "02.10.2026" => "2026-10-02", "2.10.2026" => "2026-10-02", " 2026-10-02 " => "2026-10-02",
      "2000-01-01" => "2000-01-01", "2100-12-31" => "2100-12-31", "02.1.2026" => "2026-01-02", "2.01.2026" => "2026-01-02",
      "2028-02-29" => "2028-02-29", "29.02.2028" => "2028-02-29", "\t2026-10-02\u{a0}" => "2026-10-02",
    }.each do |text, day|
      it "reads #{text.inspect} as the UTC date #{day}" do
        parsed = Domain.parse_date(text)
        parsed.should eq date(day)
        parsed.location.should eq Time::Location::UTC
      end
    end

    {
      "yesterday" => "„yesterday“", "2026-02-30" => "„2026-02-30“", "2027-02-29" => "„2027-02-29“",
      "31.4.2026" => "„31.4.2026“", "2026-9-01" => "„2026-9-01“", "2.1.26" => "„2.1.26“", "123.1.2026" => "„123.1.2026“",
      "+2026-01-01" => "„+2026-01-01“", "+999-01-01" => "„+999-01-01“", "0000-01-01" => "„0000-01-01“",
      "2026-00-10" => "„2026-00-10“", "2026-13-01" => "„2026-13-01“", "00.01.2026" => "„00.01.2026“",
      "2026-10-02x" => "„2026-10-02x“", "2026–10–02" => "„2026–10–02“",
      "\u{ff11}\u{ff12}.1.2026" => "„\u{ff11}\u{ff12}.1.2026“", "\u{661}.1.2026" => "„\u{661}.1.2026“",
    }.each do |text, shown|
      it "rejects #{text.inspect} as an invalid date" do
        expect_invalid("Ungültiges Datum #{shown}.") { Domain.parse_date(text) }
      end
    end

    ["", " \u{3000} "].each do |text|
      it "asks for a date when given #{text.inspect}" do
        expect_invalid("Bitte ein Datum angeben.") { Domain.parse_date(text) }
      end
    end

    ["1999-12-31", "2101-01-01", "0026-10-02", "9999-12-31"].each do |text|
      it "rejects #{text} as outside the years 2000 to 2100" do
        expect_invalid("Das Datum „#{text}“ liegt nicht zwischen 2000 und 2100.") { Domain.parse_date(text) }
      end
    end
  end

  it "writes a date the German way" do
    Domain.format_date(d("2026-10-02")).should eq "02.10.2026"
    Domain.format_date(Time.utc(26, 10, 2)).should eq "02.10.0026"
  end

  it "takes the calendar date of a moment in a time zone" do
    berlin = Time::Location.load("Europe/Berlin")
    got = Domain.date_of(Time.utc(2026, 10, 1, 23, 30).in(berlin))
    got.to_s(Domain::DATE_LAYOUT).should eq "2026-10-02"
    got.location.should eq Time::Location::UTC
  end

  describe ".next_at_hour" do
    berlin = Time::Location.load("Europe/Berlin")

    {
      "2026-10-02 01:00" => "2026-10-02 03:00",
      "2026-10-02 03:00" => "2026-10-03 03:00",
      "2026-10-02 23:59" => "2026-10-03 03:00",
      "2026-10-24 23:00" => "2026-10-25 03:00",
    }.each do |now, due|
      it "plans 03:00 after #{now} for #{due}" do
        Domain.next_at_hour(Time.parse(now, "%F %R", berlin), 3).to_s("%F %R").should eq due
      end
    end
  end
end
