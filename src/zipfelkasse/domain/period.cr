module Zipfelkasse::Domain
  enum PeriodUnit
    Year
    Month
    Week
  end

  # Periods are labelled "2026", "2026-09" and ISO week "2026-W40".
  module Period
    extend self

    def label(unit : PeriodUnit, day : Time) : String
      case unit
      in .year? then day.to_s("%Y")
      in .week?
        year, week = day.calendar_week
        "%d-W%02d" % {year, week}
      in .month? then day.to_s("%Y-%m")
      end
    end

    def labels(unit : PeriodUnit, first : Time, last : Time) : Array(String)
      result = [] of String
      return result if last < first
      final = label(unit, last)
      day = start_of(unit, first)
      loop do
        current = label(unit, day)
        result << current
        break if current >= final
        day = next_start(unit, day)
      end
      result
    end

    def last_day(unit : PeriodUnit, day : Time) : Time
      next_start(unit, start_of(unit, day)) - 1.day
    end

    def first_day(unit : PeriodUnit, label : String) : Time?
      case unit
      in .year?
        m = /\A(\d{1,4})/.match(label) || return
        Time.utc(m[1].to_i, 1, 1)
      in .week?
        m = /\A(\d{1,4})-W(\d{1,2})/.match(label) || return
        # 4 January is always in week 1.
        start_of(unit, Time.utc(m[1].to_i, 1, 4)) + (7 * (m[2].to_i - 1)).days
      in .month?
        m = /\A(\d{1,4})-(\d{1,2})/.match(label) || return
        Time.utc(m[1].to_i, 1, 1).shift(months: m[2].to_i - 1)
      end
    rescue ArgumentError
      nil
    end

    # Moves a label by years; "" stays "". Week 53 becomes week 52 in a year
    # without week 53.
    def shift_label(label : String, years : Int32) : String
      y = label[0, 4].to_i?(whitespace: false) || return label
      y += years
      return "%04d-W52" % y if label.ends_with?("-W53") && Time.utc(y, 12, 28).calendar_week[1] < 53
      "%04d" % y + (label[4..]? || "")
    end

    private def start_of(unit : PeriodUnit, day : Time) : Time
      case unit
      in .year?  then Time.utc(day.year, 1, 1)
      in .week?  then Time.utc(day.year, day.month, day.day) - (day.day_of_week.value - 1).days
      in .month? then Time.utc(day.year, day.month, 1)
      end
    end

    private def next_start(unit : PeriodUnit, day : Time) : Time
      case unit
      in .year?  then day.shift(years: 1)
      in .week?  then day + 7.days
      in .month? then day.shift(months: 1)
      end
    end
  end
end
