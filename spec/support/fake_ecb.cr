require "http/server"

# Fake of https://www.ecb.europa.eu/stats/eurofxref/ with deterministic rates
# for every business day from 2023-12-01 until `last_day`.
class FakeECB
  BASE = {
    "USD" => 1.0912, "JPY" => 158.37, "BGN" => 1.9558, "CZK" => 24.871,
    "DKK" => 7.4586, "GBP" => 0.85412, "HUF" => 389.65, "PLN" => 4.3155,
    "SEK" => 11.2635, "CHF" => 0.94315, "NOK" => 11.6420, "TRY" => 38.9142,
    "AUD" => 1.6538, "CAD" => 1.4921, "IDR" => 17342.81, "THB" => 38.215,
  }

  FIRST_DAY = Time.utc(2023, 12, 1)

  RECENT  = "eurofxref-hist-90d.xml"
  HISTORY = "eurofxref-hist.xml"

  # Good Friday and Easter Monday; New Year, 1 May and Christmas are fixed.
  EASTER_HOLIDAYS = {Time.utc(2024, 3, 29), Time.utc(2024, 4, 1), Time.utc(2025, 4, 18), Time.utc(2025, 4, 21),
                     Time.utc(2026, 4, 3), Time.utc(2026, 4, 6)}

  EMPTY_XML = %(<?xml version="1.0" encoding="UTF-8"?>\n<gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">\n\t<Cube>\n\t</Cube>\n</gesmes:Envelope>\n)

  # Answers every request with this HTTP status, with :empty (a valid XML file
  # without rates), with :broken (a cut-off XML file) or with :network (the
  # connection is closed).
  property failure : Int32 | Symbol | Nil = nil
  property last_day : Time
  getter requests = [] of String
  getter agents = [] of String
  getter port : Int32
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

  def file(name : String) : String
    case name
    when RECENT  then xml(days.select { |day| day > last_day - 90.days })
    when HISTORY then xml(days)
    else              raise "unknown ECB file #{name}"
    end
  end

  def self.business_day?(day : Time) : Bool
    !(day.saturday? || day.sunday? || {day.month, day.day}.in?({1, 1}, {5, 1}, {12, 25}, {12, 26}) ||
      EASTER_HOLIDAYS.includes?(day))
  end

  private def handle(ctx : HTTP::Server::Context) : Nil
    name = ctx.request.path.lstrip('/')
    requests << name
    agents << (ctx.request.headers["User-Agent"]? || "")
    @gate.try(&.receive?)
    ctx.response.content_type = "text/xml"
    case failure = @failure
    when Int32
      ctx.response.status_code = failure
      ctx.response.print "broken"
    when :network then ctx.response.@io.close
    when :empty   then ctx.response.print EMPTY_XML
    when :broken  then ctx.response.print "<broken"
    when nil
      if name.in?(RECENT, HISTORY)
        ctx.response.print file(name)
      else
        ctx.response.status_code = 404
      end
    end
  end

  # Newest first, like the ECB files.
  private def days : Array(Time)
    (0..(last_day - FIRST_DAY).days).map { |i| last_day - i.days }.select { |day| FakeECB.business_day?(day) }
  end

  private def xml(days : Array(Time)) : String
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
    end
  end
end
