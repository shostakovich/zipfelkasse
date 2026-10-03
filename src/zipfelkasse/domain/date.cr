module Zipfelkasse::Domain
  # Calendar dates (expense date, occurrences) are `Time` at 00:00 UTC, so
  # they compare and store without time-zone surprises.

  DATE_LAYOUT = "%Y-%m-%d"

  # Plausible years for calendar dates. Guards against typos ("0026") and
  # against huge loops for recurrences starting at an absurd date.
  MIN_YEAR = 2000
  MAX_YEAR = 2100

  def date_of(t : Time) : Time
    Time.utc(t.year, t.month, t.day)
  end

  def parse_date(s : String) : Time
    s = s.strip
    raise ValidationError.new("Bitte ein Datum angeben.") if s.empty?
    date = date_fields(s) || raise ValidationError.new("Ungültiges Datum „#{s}“.")
    unless MIN_YEAR <= date.year <= MAX_YEAR
      raise ValidationError.new("Das Datum „#{s}“ liegt nicht zwischen #{MIN_YEAR} und #{MAX_YEAR}.")
    end
    date
  end

  private def date_fields(s : String) : Time?
    return unless s.ascii_only? # also keeps invalid UTF-8 away from the regex engine
    ymd = if m = s.match(/\A([0-9]{4})-([0-9]{2})-([0-9]{2})\z/)
            {m[1], m[2], m[3]}
          elsif m = s.match(/\A([0-9]{1,2})\.([0-9]{1,2})\.([0-9]{4})\z/)
            {m[3], m[2], m[1]}
          end
    return unless ymd
    year, month, day = ymd.map(&.to_i)
    Time.utc(year, month, day)
  rescue ArgumentError
    nil
  end

  def format_date(t : Time) : String
    t.to_s("%d.%m.%Y")
  end

  enum Frequency
    Weekly
    Monthly
    Yearly

    def key : String
      to_s.underscore
    end

    def self.from_key?(key : String) : self?
      values.find { |member| member.key == key }
    end
  end

  # Occurrences are always computed from the anchor (n=0): an anchor on
  # January 31 yields February 28/29, then March 31 again.
  def occurrence(f : Frequency, anchor : Time, n : Int32) : Time
    anchor = date_of(anchor)
    case f
    in .weekly?  then anchor.shift(days: 7 * n)
    in .monthly? then anchor.shift(months: n)
    in .yearly?  then anchor.shift(months: 12 * n)
    end
  end

  def next_date(f : Frequency, anchor : Time, after : Time) : Time
    anchor, after = date_of(anchor), date_of(after)
    return anchor if after < anchor
    n = case f
        in .weekly?  then (after - anchor).total_days.to_i.tdiv(7)
        in .monthly? then months_between(anchor, after)
        in .yearly?  then months_between(anchor, after).tdiv(12)
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
end
