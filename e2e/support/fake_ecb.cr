require "http/server"
require "compress/zip"

module E2E
  # Fake of https://www.ecb.europa.eu/stats/eurofxref/ with deterministic
  # rates for every TARGET business day from 2023-12-01 until `last_day`.
  class FakeECB
    # Base rates (units per 1 EUR) of the currencies the fake publishes.
    BASE = {
      "USD" => 1.0912, "JPY" => 158.37, "BGN" => 1.9558, "CZK" => 24.871,
      "DKK" => 7.4586, "GBP" => 0.85412, "HUF" => 389.65, "PLN" => 4.3155,
      "SEK" => 11.2635, "CHF" => 0.94315, "NOK" => 11.6420, "TRY" => 38.9142,
      "AUD" => 1.6538, "CAD" => 1.4921, "IDR" => 17342.81, "THB" => 38.215,
    }

    FIRST_DAY = Time.utc(2023, 12, 1)

    getter requests = [] of String
    getter port : Int32
    @server : HTTP::Server
    @days : Array(Time)

    def initialize(@last_day : Time = Time.utc(2026, 10, 2))
      @days = business_days.reverse # newest first, like the ECB files
      @server = HTTP::Server.new { |ctx| handle(ctx) }
      @port = @server.bind_tcp("127.0.0.1", 0).port
      spawn { @server.listen }
    end

    def base_url : String
      "http://127.0.0.1:#{@port}/"
    end

    def close : Nil
      @server.close
    end

    private def handle(ctx)
      file = ctx.request.path.lstrip('/')
      @requests << file
      case file
      when "eurofxref-daily.xml"
        xml(ctx, @days.first(1))
      when "eurofxref-hist-90d.xml"
        xml(ctx, @days.select { |d| d > @last_day - 90.days })
      when "eurofxref-hist.zip"
        ctx.response.content_type = "application/zip"
        ctx.response.write(hist_zip)
      else
        ctx.response.status_code = 404
        ctx.response.print "not found"
      end
    end

    # Rate of a currency on a day: the base rate with a small, deterministic
    # wobble, rounded to the precision the ECB publishes.
    def rate(currency : String, day : Time) : String
      base = BASE[currency]
      n = (day - FIRST_DAY).days
      wobble = 1 + 0.03 * Math.sin(n / 17.0 + currency.chars.sum(&.ord)) + 0.0004 * (n % 7)
      digits = base >= 1000 ? 2 : (base >= 100 ? 3 : (base >= 10 ? 4 : 5))
      v = base * wobble
      "%.#{digits}f" % v
    end

    private def xml(ctx, days)
      ctx.response.content_type = "text/xml"
      io = ctx.response
      io << %(<?xml version="1.0" encoding="UTF-8"?>\n)
      io << %(<gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">\n)
      io << %(\t<gesmes:subject>Reference rates</gesmes:subject>\n)
      io << %(\t<gesmes:Sender>\n\t\t<gesmes:name>European Central Bank</gesmes:name>\n\t</gesmes:Sender>\n)
      io << %(\t<Cube>\n)
      days.each do |d|
        io << %(\t\t<Cube time=') << d.to_s("%Y-%m-%d") << %('>\n)
        BASE.each_key do |cur|
          io << %(\t\t\t<Cube currency=') << cur << %(' rate=') << rate(cur, d) << %('/>\n)
        end
        io << %(\t\t</Cube>\n)
      end
      io << %(\t</Cube>\n</gesmes:Envelope>\n)
    end

    private def hist_zip : Bytes
      csv = String.build do |io|
        io << "Date," << BASE.keys.join(",") << ",CYP,\n"
        @days.each do |d|
          io << d.to_s("%Y-%m-%d") << ","
          BASE.each_key { |cur| io << rate(cur, d) << "," }
          io << "N/A,\n"
        end
      end
      buf = IO::Memory.new
      Compress::Zip::Writer.open(buf) do |zip|
        zip.add("eurofxref-hist.csv", csv)
      end
      buf.to_slice
    end

    private def business_days : Array(Time)
      days = [] of Time
      d = FIRST_DAY
      while d <= @last_day
        days << d if FakeECB.business_day?(d)
        d += 1.day
      end
      days
    end

    def self.business_day?(d : Time) : Bool
      return false if d.saturday? || d.sunday?
      return false if {d.month, d.day}.in?({1, 1}, {5, 1}, {12, 25}, {12, 26})
      easter = easter_sunday(d.year)
      d != easter - 2.days && d != easter + 1.day
    end

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
  end
end
