require "../spec_helper"

private alias D = Zipfelkasse::Domain

private def d(s : String) : Time
  Time.parse_utc(s, D::DATE_LAYOUT)
end

describe Zipfelkasse::Domain::Period do
  it "finds the first day of a period by its label and back" do
    [
      {D::PeriodUnit::Year, "2026", "2026-01-01"},
      {D::PeriodUnit::Month, "2026-09", "2026-09-01"},
      {D::PeriodUnit::Week, "2026-W01", "2025-12-29"},
      {D::PeriodUnit::Week, "2026-W40", "2026-09-28"},
      {D::PeriodUnit::Week, "2020-W53", "2020-12-28"},
    ].each do |unit, label, first_day|
      got = D::Period.first_day(unit, label).not_nil!
      got.to_s(D::DATE_LAYOUT).should eq first_day
      D::Period.label(unit, got).should eq label
    end
    D::Period.first_day(D::PeriodUnit::Month, "nonsense").should be_nil
  end

  it "lists the labels from the first to the last period" do
    D::Period.labels(D::PeriodUnit::Week, d("2026-09-30"), d("2026-10-12")).should eq %w(2026-W40 2026-W41 2026-W42)
    D::Period.labels(D::PeriodUnit::Year, d("2026-09-30"), d("2026-09-29")).should be_empty
  end

  it "finds the last day of a period" do
    D::Period.last_day(D::PeriodUnit::Month, d("2024-02-10")).should eq d("2024-02-29")
    D::Period.last_day(D::PeriodUnit::Week, d("2026-10-03")).should eq d("2026-10-04")
    D::Period.last_day(D::PeriodUnit::Year, d("2026-10-03")).should eq d("2026-12-31")
  end

  it "moves labels by a year" do
    {"2025-09" => "2026-09", "2025-W40" => "2026-W40", "2025" => "2026", "" => "",
     "2020-W53" => "2021-W52", "2025-W53" => "2026-W53"}.each do |input, want|
      D::Period.shift_label(input, 1).should eq want
    end
  end

  it "moves a date by a year and clamps 29 February" do
    {"2024-02-29" => "2023-02-28", "2024-03-31" => "2023-03-31", "2023-02-28" => "2022-02-28"}.each do |input, want|
      d(input).shift(years: -1).should eq d(want)
    end
    d("2023-02-28").shift(years: 1).should eq d("2024-02-28")
  end
end
