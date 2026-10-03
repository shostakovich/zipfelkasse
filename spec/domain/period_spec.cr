require "../spec_helper"

private def d(s : String) : Time
  Time.parse_utc(s, "%F")
end

describe Domain::Period do
  it "finds the first day of a period by its label and back" do
    [
      {Domain::PeriodUnit::Year, "2026", "2026-01-01"},
      {Domain::PeriodUnit::Month, "2026-09", "2026-09-01"},
      {Domain::PeriodUnit::Week, "2026-W01", "2025-12-29"},
      {Domain::PeriodUnit::Week, "2026-W40", "2026-09-28"},
      {Domain::PeriodUnit::Week, "2020-W53", "2020-12-28"},
    ].each do |unit, label, first_day|
      got = Domain::Period.first_day(unit, label).not_nil!
      got.to_s("%F").should eq first_day
      Domain::Period.label(unit, got).should eq label
    end
    Domain::Period.first_day(Domain::PeriodUnit::Month, "nonsense").should be_nil
  end

  it "lists the labels from the first to the last period" do
    Domain::Period.labels(Domain::PeriodUnit::Week, d("2026-09-30"), d("2026-10-12")).should eq %w(2026-W40 2026-W41 2026-W42)
    Domain::Period.labels(Domain::PeriodUnit::Year, d("2026-09-30"), d("2026-09-29")).should be_empty
  end

  it "finds the last day of a period" do
    Domain::Period.last_day(Domain::PeriodUnit::Month, d("2024-02-10")).should eq d("2024-02-29")
    Domain::Period.last_day(Domain::PeriodUnit::Week, d("2026-10-03")).should eq d("2026-10-04")
    Domain::Period.last_day(Domain::PeriodUnit::Year, d("2026-10-03")).should eq d("2026-12-31")
  end

  it "moves labels by a year" do
    {"2025-09" => "2026-09", "2025-W40" => "2026-W40", "2025" => "2026", "" => "",
     "2020-W53" => "2021-W52", "2025-W53" => "2026-W53"}.each do |input, want|
      Domain::Period.shift_label(input, 1).should eq want
    end
  end
end
