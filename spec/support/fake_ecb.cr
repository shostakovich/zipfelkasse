require "http/server"
require "compress/zip"

# Fake of https://www.ecb.europa.eu/stats/eurofxref/ with deterministic rates
# for every TARGET business day from 2023-12-01 until `last_day`.
class FakeECB
  BASE = {
    "USD" => 1.0912, "JPY" => 158.37, "BGN" => 1.9558, "CZK" => 24.871,
    "DKK" => 7.4586, "GBP" => 0.85412, "HUF" => 389.65, "PLN" => 4.3155,
    "SEK" => 11.2635, "CHF" => 0.94315, "NOK" => 11.6420, "TRY" => 38.9142,
    "AUD" => 1.6538, "CAD" => 1.4921, "IDR" => 17342.81, "THB" => 38.215,
  }

  FIRST_DAY = Time.utc(2023, 12, 1)

  DAILY   = "eurofxref-daily.xml"
  LAST_90 = "eurofxref-hist-90d.xml"
  HIST    = "eurofxref-hist.zip"

  EMPTY_XML = %(<?xml version="1.0" encoding="UTF-8"?>\n<gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">\n\t<Cube>\n\t</Cube>\n</gesmes:Envelope>\n)

  # Answers every request with this HTTP status, or with :empty (a valid XML
  # file without rates), or with :network (the connection is closed).
  property failure : Int32 | Symbol | Nil = nil
  getter last_day : Time
  getter requests = [] of String
  getter agents = [] of String
  getter port : Int32
  @days : Array(Time)?
  @gate : Channel(Nil)?
  @server : HTTP::Server

  def initialize(@last_day : Time = Time.utc(2026, 10, 2))
    @server = HTTP::Server.new { |ctx| handle(ctx) }
    @port = @server.bind_tcp("127.0.0.1", 0).port
    spawn { @server.listen unless @server.closed? }
  end

  def base_url : String
    "http://127.0.0.1:#{@port}/"
  end

  def close : Nil
    release
    @server.close
  end

  def last_day=(day : Time) : Time
    @days = nil
    @last_day = day
  end

  # Requests hang until `release`.
  def block : Nil
    @gate = Channel(Nil).new
  end

  def release : Nil
    @gate.try { |gate| gate.close unless gate.closed? }
  end

  def count(file : String) : Int32
    requests.count(file)
  end

  # Rate of a currency on a day: the base rate with a small, deterministic
  # wobble, rounded to the precision the ECB publishes.
  def rate(currency : String, day : Time) : String
    base = BASE[currency]
    n = (day - FIRST_DAY).days
    wobble = 1 + 0.03 * Math.sin(n / 17.0 + currency.chars.sum(&.ord)) + 0.0004 * (n % 7)
    digits = base >= 1000 ? 2 : (base >= 100 ? 3 : (base >= 10 ? 4 : 5))
    "%.#{digits}f" % (base * wobble)
  end

  def file(name : String) : Bytes
    case name
    when DAILY   then xml(days.first(1))
    when LAST_90 then xml(days.select { |day| day > last_day - 90.days })
    when HIST    then hist_zip
    else              raise "unknown ECB file #{name}"
    end
  end

  def self.business_day?(day : Time) : Bool
    return false if day.saturday? || day.sunday?
    return false if {day.month, day.day}.in?({1, 1}, {5, 1}, {12, 25}, {12, 26})
    easter = easter_sunday(day.year)
    day != easter - 2.days && day != easter + 1.day
  end

  def self.easter_sunday(year : Int32) : Time
    a = year % 19
    b, c = year // 100, year % 100
    d, e = b // 4, b % 4
    f = (b + 8) // 25
    g = (b - f + 1) // 3
    h = (19 * a + b - d - g + 15) % 30
    i, k = c // 4, c % 4
    l = (32 + 2 * e + 2 * i - h - k) % 7
    m = (a + 11 * h + 22 * l) // 451
    Time.utc(year, (h + l - 7 * m + 114) // 31, (h + l - 7 * m + 114) % 31 + 1)
  end

  private def handle(ctx : HTTP::Server::Context) : Nil
    name = ctx.request.path.lstrip('/')
    requests << name
    agents << (ctx.request.headers["User-Agent"]? || "")
    @gate.try(&.receive?)
    case failure = @failure
    when Int32
      ctx.response.status_code = failure
      ctx.response.print "broken"
    when :network
      ctx.response.@io.close
    when :empty
      ctx.response.content_type = "text/xml"
      ctx.response.print EMPTY_XML
    else
      serve(ctx, name)
    end
  end

  private def serve(ctx : HTTP::Server::Context, name : String) : Nil
    case name
    when DAILY, LAST_90
      ctx.response.content_type = "text/xml"
      ctx.response.write(file(name))
    when HIST
      ctx.response.content_type = "application/zip"
      ctx.response.write(file(name))
    else
      ctx.response.status_code = 404
      ctx.response.print "not found"
    end
  end

  # Newest first, like the ECB files.
  private def days : Array(Time)
    @days ||= begin
      days = [] of Time
      day = FIRST_DAY
      while day <= last_day
        days << day if FakeECB.business_day?(day)
        day += 1.day
      end
      days.reverse!
    end
  end

  private def xml(days : Array(Time)) : Bytes
    String.build do |io|
      io << %(<?xml version="1.0" encoding="UTF-8"?>\n)
      io << %(<gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">\n)
      io << %(\t<gesmes:subject>Reference rates</gesmes:subject>\n)
      io << %(\t<gesmes:Sender>\n\t\t<gesmes:name>European Central Bank</gesmes:name>\n\t</gesmes:Sender>\n)
      io << %(\t<Cube>\n)
      days.each do |day|
        io << %(\t\t<Cube time=') << day.to_s("%Y-%m-%d") << %('>\n)
        BASE.each_key do |currency|
          io << %(\t\t\t<Cube currency=') << currency << %(' rate=') << rate(currency, day) << %('/>\n)
        end
        io << %(\t\t</Cube>\n)
      end
      io << %(\t</Cube>\n</gesmes:Envelope>\n)
    end.to_slice
  end

  # The history has one more column than the others: a currency without
  # rates ("N/A") and a trailing comma, as in the real file.
  private def hist_zip : Bytes
    csv = String.build do |io|
      io << "Date," << BASE.keys.join(",") << ",CYP,\n"
      days.each do |day|
        io << day.to_s("%Y-%m-%d") << ","
        BASE.each_key { |currency| io << rate(currency, day) << "," }
        io << "N/A,\n"
      end
    end
    buffer = IO::Memory.new
    Compress::Zip::Writer.open(buffer) { |zip| zip.add("eurofxref-hist.csv", csv) }
    buffer.to_slice
  end
end
