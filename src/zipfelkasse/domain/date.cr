module Zipfelkasse::Domain
  # Calendar dates (expense date, occurrences) are `Time` at 00:00 UTC, so
  # they compare and store without time-zone surprises.

  # The storage and HTML <input type=date> format.
  DATE_LAYOUT = "%Y-%m-%d"

  # Stands in where a `Time` is required but none is known; stored and
  # exported as 0001-01-01T00:00:00Z.
  UNSET_TIME = Time.utc(1, 1, 1)

  # Plausible years for calendar dates. Guards against typos ("0026") and
  # against huge loops for recurrences starting at an absurd date.
  MIN_YEAR = 2000
  MAX_YEAR = 2100

  def date_of(t : Time) : Time
    Time.utc(t.year, t.month, t.day)
  end

  def today(loc : Time::Location) : Time
    date_of(Time.local(loc))
  end

  def parse_date(s : String) : Time
    s = s.strip
    raise ValidationError.new("Bitte ein Datum angeben.") if s.empty?
    year, month, day = date_fields(s) || raise ValidationError.new("Ungültiges Datum „#{s}“.")
    unless MIN_YEAR <= year <= MAX_YEAR
      raise ValidationError.new("Das Datum „#{s}“ liegt nicht zwischen #{MIN_YEAR} und #{MAX_YEAR}.")
    end
    Time.utc(year, month, day)
  end

  private def date_fields(s : String) : {Int32, Int32, Int32}?
    return unless s.ascii_only? # also keeps invalid UTF-8 away from the regex engine
    ymd = if m = s.match(/\A([0-9]{4})-([0-9]{2})-([0-9]{2})\z/)
            {m[1], m[2], m[3]}
          elsif m = s.match(/\A([0-9]{1,2})\.([0-9]{1,2})\.([0-9]{4})\z/)
            {m[3], m[2], m[1]}
          end
    return unless ymd
    year, month, day = ymd.map(&.to_i)
    {year, month, day} if 1 <= month <= 12 && 1 <= day <= days_in(year, month)
  end

  def format_date(t : Time?) : String
    return "" if t.nil? || t == UNSET_TIME
    t.to_s("%d.%m.%Y")
  end

  record Frequency, value : String do
    def valid? : Bool
      self.in?(FREQUENCIES)
    end

    def label : String
      case self
      when FREQ_WEEKLY  then "Wöchentlich"
      when FREQ_MONTHLY then "Monatlich"
      when FREQ_YEARLY  then "Jährlich"
      else                   value
      end
    end

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

  # Occurrences are always computed from the anchor (n=0): an anchor on
  # January 31 yields February 28/29, then March 31 again.
  def occurrence(f : Frequency, anchor : Time, n : Int32) : Time
    anchor = date_of(anchor)
    case f
    when FREQ_WEEKLY  then anchor.shift(days: 7 * n)
    when FREQ_MONTHLY then add_months_clamped(anchor, n)
    when FREQ_YEARLY  then add_months_clamped(anchor, 12 * n)
    else                   anchor
    end
  end

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

  # Truncating division and remainder, then the fix-up for negative months.
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
  # (Crystal's `Time.days_in_month` only accepts 1–9999).
  private def days_in(year : Int32, month : Int32) : Int32
    return 29 if month == 2 && year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}[month - 1]
  end
end
