module Zipfelkasse::GoCompat
  # Go's time.RFC3339 output: seconds, `Z` for a zero offset.
  def self.rfc3339(t : Time) : String
    t.to_s(t.offset == 0 ? "%Y-%m-%dT%H:%M:%SZ" : "%Y-%m-%dT%H:%M:%S%:z")
  end

  # Go's time.RFC3339Nano output: nanoseconds without trailing zeros (and
  # without the dot when nothing is left).
  def self.rfc3339_nano(t : Time) : String
    frac = t.nanosecond.to_s.rjust(9, '0').rstrip('0')
    zone = t.offset == 0 ? "Z" : t.to_s("%:z")
    t.to_s("%Y-%m-%dT%H:%M:%S") + (frac.empty? ? "" : ".#{frac}") + zone
  end

  # time.Parse(time.RFC3339, s): accepts fractions and offsets; nil if s is
  # not such a timestamp.
  def self.parse_rfc3339(s : String) : Time?
    return nil unless s.matches?(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?(Z|[+-]\d\d:\d\d)\z/)
    Time.parse_rfc3339(s)
  rescue Time::Format::Error | ArgumentError
    nil
  end

  # Go's Duration.String: "0s", "1.5s", "2m30s", "1h0m0s", "500ms", "3µs".
  def self.format_duration(d : Time::Span) : String
    ns = d.total_nanoseconds.to_i64
    return "0s" if ns == 0
    neg = ns < 0
    u = ns.abs.to_u64
    s = if u < 1_000_000_000
          if u < 1_000
            "#{u}ns"
          elsif u < 1_000_000
            "#{frac(u, 3)}µs"
          else
            "#{frac(u, 6)}ms"
          end
        else
          secs = frac(u % 60_000_000_000, 9) + "s"
          mins = u // 60_000_000_000
          if mins == 0
            secs
          elsif mins < 60
            "#{mins}m#{secs}"
          else
            "#{mins // 60}h#{mins % 60}m#{secs}"
          end
        end
    neg ? "-#{s}" : s
  end

  # v / 10^digits with the fraction trimmed of trailing zeros.
  private def self.frac(v : UInt64, digits : Int32) : String
    scale = 10_u64 ** digits
    whole, rest = v // scale, v % scale
    f = rest.to_s.rjust(digits, '0').rstrip('0')
    f.empty? ? whole.to_s : "#{whole}.#{f}"
  end
end
