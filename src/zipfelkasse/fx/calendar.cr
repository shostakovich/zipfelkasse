module Zipfelkasse::FX
  # The ECB publishes reference rates on TARGET business days around 16:00
  # CET/CEST: Monday to Friday except New Year's Day, Good Friday, Easter
  # Monday, 1 May, 25 and 26 December. From 16:30 Europe/Berlin on, the day's
  # rates count as published.
  PUBLISH_HOUR   = 16
  PUBLISH_MINUTE = 30

  # d is a calendar date (00:00 UTC).
  def self.business_day?(d : Time) : Bool
    return false if d.saturday? || d.sunday?
    return false if {d.month, d.day}.in?({1, 1}, {5, 1}, {12, 25}, {12, 26})
    easter = easter_sunday(d.year)
    d != easter.shift(days: -2) && d != easter.shift(days: 1)
  end

  def self.last_business_day(d : Time) : Time
    until business_day?(d)
      d = d.shift(days: -1)
    end
    d
  end

  # Anonymous Gregorian algorithm (Meeus/Jones/Butcher).
  def self.easter_sunday(y : Int32) : Time
    a = y % 19
    b, c = y // 100, y % 100
    d, e = b // 4, b % 4
    f = (b + 8) // 25
    g = (b - f + 1) // 3
    h = (19 * a + b - d - g + 15) % 30
    i, k = c // 4, c % 4
    l = (32 + 2 * e + 2 * i - h - k) % 7
    m = (a + 11 * h + 22 * l) // 451
    Time.utc(y, (h + l - 7 * m + 114) // 31, (h + l - 7 * m + 114) % 31 + 1)
  end

  # The next publication strictly after now, in now's zone (meant for
  # Europe/Berlin).
  def self.next_publish(now : Time) : Time
    day = Time.utc(now.year, now.month, now.day)
    loop do
      t = Time.local(day.year, day.month, day.day, PUBLISH_HOUR, PUBLISH_MINUTE, location: now.location)
      return t if t > now && business_day?(day)
      day = day.shift(days: 1)
    end
  end
end
