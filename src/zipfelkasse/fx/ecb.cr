require "http/client"
require "xml"

module Zipfelkasse::FX
  DEFAULT_BASE_URL = "https://www.ecb.europa.eu/stats/eurofxref/"
  RECENT           = "eurofxref-hist-90d.xml"
  HISTORY          = "eurofxref-hist.xml"

  USER_AGENT    = "zipfelkasse/1.0 (self-hosted expense tracker; ECB reference rates)"
  MAX_BODY_SIZE = 32 << 20

  class FetchError < Exception
    def initialize(reason : String)
      super("Die EZB-Kurse konnten nicht geladen werden (#{reason}). Bitte später erneut versuchen oder den Kurs von Hand eintragen.")
    end
  end

  # <gesmes:Envelope><Cube><Cube time="…"><Cube currency="USD" rate="1.1"/>…
  def self.parse_xml(xml : String) : Array(Domain::FXRate)
    doc = begin
      # Without the default RECOVER option: a cut-off file must fail, not
      # yield its first rates (the last one possibly cut, "1.1298" as "1").
      XML.parse(xml, XML::ParserOptions::NONET)
    rescue ex : XML::Error
      raise "xml: #{ex.message}"
    end
    rates = [] of Domain::FXRate
    root = doc.root || return rates
    cubes(root).each do |outer|
      cubes(outer).each do |day|
        time = day["time"]? || ""
        date = Store.parse_date?(time) || raise "xml: date #{time.inspect}"
        cubes(day).each do |c|
          rate, currency = parse_ecb_rate(c["rate"]? || ""), c["currency"]? || ""
          rates << Domain::FXRate.new(currency, date, rate, Domain::FXSource::Ecb) if rate && Domain.valid_currency_code?(currency)
        end
      end
    end
    rates
  end

  private def self.cubes(node : XML::Node) : Array(XML::Node)
    node.children.select { |n| n.element? && n.name == "Cube" }
  end

  # "N/A", empty, <= 0 or absurdly large gives nil.
  def self.parse_ecb_rate(s : String) : Float64?
    f = s.strip.to_f?(whitespace: false)
    f if f && f > 0 && f <= 1e12
  end
end
