require "../spec_helper"

private def berlin(text : String) : Time
  Time.parse(text, "%Y-%m-%d %H:%M", Time::Location.load("Europe/Berlin"))
end

describe "ECB publication calendar" do
  it "computes Easter Sunday" do
    {2024 => "2024-03-31", 2025 => "2025-04-20", 2026 => "2026-04-05", 2027 => "2027-03-28"}.each do |year, easter|
      FX.easter_sunday(year).should eq date(easter)
    end
  end

  it "knows the TARGET business days, not Good Friday, Easter Monday, 1 May and Christmas" do
    {
      "2026-10-02" => true, "2026-10-05" => true, "2026-12-24" => true,
      "2026-10-03" => false, "2026-10-04" => false,
      "2026-04-03" => false, "2026-04-06" => false,
      "2026-05-01" => false, "2026-12-25" => false, "2027-01-01" => false,
    }.each do |day, business_day|
      FX.business_day?(date(day)).should eq(business_day), "business_day?(#{day})"
    end
  end

  it "steps back to the last business day" do
    FX.last_business_day(date("2026-04-06")).should eq date("2026-04-02")
  end

  it "schedules the next publication at 16:30 Berlin time on a business day" do
    {
      "2026-10-02 12:00" => "2026-10-02 16:30",
      "2026-10-02 16:30" => "2026-10-05 16:30",
      "2026-10-02 17:00" => "2026-10-05 16:30",
      "2026-12-24 17:00" => "2026-12-28 16:30",
      "2026-03-28 10:00" => "2026-03-30 16:30",
    }.each do |now, publication|
      FX.next_publish(berlin(now)).to_s("%Y-%m-%d %H:%M").should eq publication
    end
  end

  it "keeps the publication time across a change to summer time" do
    FX.next_publish(berlin("2026-03-28 10:00")).should eq Time.utc(2026, 3, 30, 14, 30)
  end
end
