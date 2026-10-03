# Go name (package domain)  → Crystal name
# DateLayout ("2006-01-02") → Domain::DATE_LAYOUT ("%Y-%m-%d", for Time#to_s / Time.parse)
# Frequency (string type)   → Domain::Frequency (struct wrapping the string; `#value`, `#to_s`)
# FreqWeekly … FreqYearly   → Domain::FREQ_WEEKLY … FREQ_YEARLY
# Frequencies               → Domain::FREQUENCIES
# time.Time{} (zero value)  → nil
module Zipfelkasse::Domain
  # Calendar dates (expense date, occurrences) are `Time` at 00:00 UTC. That
  # way they compare and store without time-zone surprises; they are stored
  # as "2006-01-02".

  # The storage and HTML <input type=date> format.
  DATE_LAYOUT = "%Y-%m-%d"

  # Plausible years for calendar dates. Guards against typos ("0026") and
  # against huge loops for recurrences starting at an absurd date.
  MIN_YEAR = 2000
  MAX_YEAR = 2100

  # Truncates the time of day and returns the calendar date of t (in t's time
  # zone) as 00:00 UTC.
  def date_of(t : Time) : Time
    Time.utc(t.year, t.month, t.day)
  end

  # Returns today's date in the time zone loc.
  def today(loc : Time::Location) : Time
    date_of(Time.local(loc))
  end

  # Parses "2006-01-02" or "02.01.2006" (also "2.1.2006"), strictly like Go's
  # time.Parse with these layouts (4-digit years, 2-digit fields except in the
  # last layout, valid days). Years outside MIN_YEAR–MAX_YEAR are rejected.
  def parse_date(s : String) : Time
    s = GoCompat.trim_space(s)
    raise ValidationError.new("Bitte ein Datum angeben.") if s.empty?
    year, month, day = date_fields(s) || raise ValidationError.new("Ungültiges Datum „#{s}“.")
    unless MIN_YEAR <= year <= MAX_YEAR
      raise ValidationError.new("Das Datum „#{s}“ liegt nicht zwischen #{MIN_YEAR} und #{MAX_YEAR}.")
    end
    Time.utc(year, month, day)
  end

  # Year, month and day of s in the layout "2006-01-02" or "2.1.2006"
  # ("02.01.2006" is a special case of it), if it is a valid date.
  private def date_fields(s : String) : {Int32, Int32, Int32}?
    ymd = if m = s.match(/\A([0-9]{4})-([0-9]{2})-([0-9]{2})\z/)
            {m[1], m[2], m[3]}
          elsif m = s.match(/\A([0-9]{1,2})\.([0-9]{1,2})\.([0-9]{4})\z/)
            {m[3], m[2], m[1]}
          end
    return unless ymd
    year, month, day = ymd.map(&.to_i)
    {year, month, day} if 1 <= month <= 12 && 1 <= day <= days_in(year, month)
  end

  # Formats German style: "02.10.2026". nil (or Go's zero time) → "".
  def format_date(t : Time?) : String
    return "" if t.nil? || t == GO_ZERO_TIME
    t.to_s("%d.%m.%Y")
  end

  # Go's zero time.Time, the instant Go treats as "not set".
  private GO_ZERO_TIME = Time.utc(1, 1, 1)

  # The interval of a recurring expense. Any string can be wrapped (unknown
  # frequencies are invalid, as in Go).
  record Frequency, value : String do
    def valid? : Bool
      self.in?(FREQUENCIES)
    end

    # Returns the German display name.
    def label : String
      case self
      when FREQ_WEEKLY  then "Wöchentlich"
      when FREQ_MONTHLY then "Monatlich"
      when FREQ_YEARLY  then "Jährlich"
      else                   value
      end
    end

    # Returns the German adverb for running text ("wiederholt sich jetzt
    # monatlich").
    def adverb : String
      case self
      when FREQ_WEEKLY  then "wöchentlich"
      when FREQ_MONTHLY then "monatlich"
      when FREQ_YEARLY  then "jährlich"
      else                   value
      end
    end

    def to_s(io : IO) : Nil
      io << value
    end
  end

  FREQ_WEEKLY  = Frequency.new("weekly")
  FREQ_MONTHLY = Frequency.new("monthly")
  FREQ_YEARLY  = Frequency.new("yearly")
  FREQUENCIES  = [FREQ_WEEKLY, FREQ_MONTHLY, FREQ_YEARLY]

  # Returns the n-th occurrence (n=0 is anchor) of a recurrence. Occurrences
  # are always computed from the anchor date: an anchor on January 31 yields
  # February 28/29, then March 31 again. Invalid frequency → anchor.
  def occurrence(f : Frequency, anchor : Time, n : Int32) : Time
    anchor = date_of(anchor)
    case f
    when FREQ_WEEKLY  then anchor.shift(days: 7 * n)
    when FREQ_MONTHLY then add_months_clamped(anchor, n)
    when FREQ_YEARLY  then add_months_clamped(anchor, 12 * n)
    else                   anchor
    end
  end

  # Returns the first occurrence of the recurrence strictly after after. If
  # after is before the anchor, that is the anchor itself.
  def next_date(f : Frequency, anchor : Time, after : Time) : Time
    anchor, after = date_of(anchor), date_of(after)
    return anchor if after < anchor || !f.valid?
    # Estimate, then step forward.
    n = case f
        when FREQ_WEEKLY  then (after - anchor).days.to_i.tdiv(7)
        when FREQ_MONTHLY then months_between(anchor, after)
        else                   months_between(anchor, after).tdiv(12)
        end
    n = Math.max(n - 1, 0)
    loop do
      t = occurrence(f, anchor, n)
      return t if t > after
      n += 1
    end
  end

  private def months_between(a : Time, b : Time) : Int32
    (b.year - a.year) * 12 + b.month - a.month
  end

  # Go's truncating division and remainder, then the fix-up for negative
  # months.
  private def add_months_clamped(t : Time, months : Int32) : Time
    y, m = t.year, t.month - 1 + months
    y += m.tdiv(12)
    m = m.remainder(12)
    if m < 0
      m += 12
      y -= 1
    end
    month = m + 1
    Time.utc(y, month, Math.min(t.day, days_in(y, month)))
  end

  # Days in the month of the proleptic Gregorian calendar, for any year
  # (Crystal's `Time.days_in_month` only accepts 1–9999; Go accepts year 0).
  private def days_in(year : Int32, month : Int32) : Int32
    return 29 if month == 2 && year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}[month - 1]
  end
end
