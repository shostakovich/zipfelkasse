require "http/client"
require "xml"
require "csv"
require "compress/zip"

module Zipfelkasse::FX
  DEFAULT_BASE_URL = "https://www.ecb.europa.eu/stats/eurofxref/"
  FILE_DAILY       = "eurofxref-daily.xml"    # last business day
  FILE_90D         = "eurofxref-hist-90d.xml" # about 90 calendar days
  FILE_HIST        = "eurofxref-hist.zip"     # everything since 1999 (CSV in a ZIP)

  USER_AGENT    = "zipfelkasse/1.0 (self-hosted expense tracker; ECB reference rates)"
  MAX_BODY_SIZE = 32 << 20

  # After a fetch, the same file is loaded again only after this time at the
  # earliest (except for an explicit refresh).
  COOLDOWN_OK    = 15.minutes
  COOLDOWN_ERROR = 1.minute

  # The latest day of a completely loaded eurofxref-hist.zip: older days are
  # fully cached, a missing day there is a real gap.
  SETTING_HIST_UNTIL = "fx.ezb_hist_bis"

  # The ECB rates could not be loaded (network, HTTP status, broken file).
  # The message is shown to the user.
  class FetchError < Exception
    getter file : String

    def initialize(@file : String, reason : String)
      super("Die EZB-Kurse konnten nicht geladen werden (#{reason}). Bitte später erneut versuchen oder den Kurs von Hand eintragen.")
    end
  end

  # A loaded file: its earliest/latest day, currencies and number of rates.
  struct LoadResult
    getter from : Time
    getter to : Time
    getter currencies : Set(String)
    getter count : Int32

    # rates must not be empty.
    def initialize(rates : Array(Domain::FXRate))
      @from = rates.min_of(&.date)
      @to = rates.max_of(&.date)
      @currencies = rates.map(&.currency).to_set
      @count = rates.size
    end

    def covers?(d : Time) : Bool
      d >= @from
    end
  end

  # eurofxref-daily.xml / eurofxref-hist-90d.xml:
  # <gesmes:Envelope><Cube><Cube time="…"><Cube currency="USD" rate="1.1"/>…
  def self.parse_xml(xml : String) : Array(Domain::FXRate)
    doc = begin
      XML.parse(xml)
    rescue ex : XML::Error
      raise "xml: #{ex.message}"
    end
    rates = [] of Domain::FXRate
    root = doc.root || return rates
    cubes(root).each do |outer|
      cubes(outer).each do |day|
        time = day["time"]? || ""
        d = parse_day(time) || raise "xml: date #{time.inspect}"
        cubes(day).each do |c|
          rate, currency = parse_ecb_rate(c["rate"]? || ""), c["currency"]? || ""
          rates << Domain::FXRate.new(currency, d, rate, Domain::FX_SOURCE_ECB) if rate && Domain.valid_currency_code?(currency)
        end
      end
    end
    rates
  end

  private def self.cubes(node : XML::Node) : Array(XML::Node)
    node.children.select { |n| n.element? && n.name == "Cube" }
  end

  # eurofxref-hist.csv inside the ZIP.
  def self.parse_hist_zip(bytes : Bytes) : Array(Domain::FXRate)
    zip = begin
      Compress::Zip::File.new(IO::Memory.new(bytes))
    rescue ex : Compress::Zip::Error | IO::Error
      raise "zip: #{ex.message}"
    end
    entry = zip.entries.find { |e| File.extname(e.filename).downcase == ".csv" } || raise "zip: no CSV file found"
    entry.open { |io| parse_hist_csv(IO::Sized.new(io, 4_i64 * MAX_BODY_SIZE)) }
  end

  # "Date,USD,JPY,…," followed by "2026-10-01,1.1298,178.49,N/A,…,".
  def self.parse_hist_csv(io : IO) : Array(Domain::FXRate)
    csv = CSV::Parser.new(io)
    header = csv.next_row || raise "csv: header: EOF"
    unless header[0]?.try(&.lchop('\u{FEFF}').strip.downcase) == "date"
      raise "csv: unexpected header #{header.inspect}"
    end
    currencies = header.map(&.strip)
    rates = [] of Domain::FXRate
    while row = csv.next_row
      next if row.empty? || row[0].strip.empty?
      d = parse_day(row[0].strip) || raise "csv: date #{row[0].inspect}"
      (1...Math.min(row.size, currencies.size)).each do |i|
        rate = parse_ecb_rate(row[i])
        rates << Domain::FXRate.new(currencies[i], d, rate, Domain::FX_SOURCE_ECB) if rate && Domain.valid_currency_code?(currencies[i])
      end
    end
    rates
  rescue ex : CSV::MalformedCSVError
    raise "csv: #{ex.message}"
  end

  # "N/A", empty, <= 0 or absurdly large gives nil.
  def self.parse_ecb_rate(s : String) : Float64?
    f = s.strip.to_f?(whitespace: false)
    f if f && f > 0 && f <= 1e12
  end

  def self.parse_day(s : String) : Time?
    Store.parse_date(s.strip) if s.strip.matches?(/\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/)
  rescue Time::Format::Error | ArgumentError
    nil
  end

  class Service
    # A running or finished fetch of a file.
    private class Load
      getter done = Channel(Nil).new
      getter at : Time = Time::UNIX_EPOCH
      @result : LoadResult?
      @error : FetchError?

      def finished? : Bool
        @done.closed?
      end

      def finish(@result : LoadResult?, @error : FetchError?, @at : Time) : Nil
        @done.close
      end

      def cooldown : Time::Span
        @error ? COOLDOWN_ERROR : COOLDOWN_OK
      end

      def wait : LoadResult
        @done.receive?
        if e = @error
          raise e
        end
        @result || raise "fetch finished without result"
      end
    end

    # Loads file from the ECB and stores its rates. The same file is never
    # loaded concurrently: further callers wait for the running fetch. Shortly
    # after a fetch its result is returned again without loading (force skips
    # this). On shutdown, running fetches are aborted and no new ones start.
    def fetch(file : String, force = false) : LoadResult
      load = @mutex.synchronize do
        current = @loads[file]?
        if current && current.finished? && (force || @clock.call - current.at >= current.cooldown)
          current = nil
        end
        current || start_fetch(file)
      end
      load.wait
    end

    private def start_fetch(file : String) : Load
      raise FetchError.new(file, "shutting down") if @stopped
      load = @loads[file] = Load.new
      @bg.spawn do
        result, error = begin
          {download(file), nil}
        rescue ex
          @d.log.warn("loading ECB rates failed", file: file, err: ex)
          {nil, FetchError.new(file, ex.message || ex.class.name)}
        end
        if result
          @d.log.info("ECB rates loaded", file: file, rates: result.count,
            from: Store.format_date(result.from), to: Store.format_date(result.to))
        end
        @mutex.synchronize { load.finish(result, error, @clock.call) }
      end
      load
    end

    private def download(file : String) : LoadResult
      uri = URI.parse(@base_url + file)
      client = HTTP::Client.new(uri)
      client.connect_timeout = 60.seconds
      client.read_timeout = 60.seconds
      client.write_timeout = 60.seconds
      body = begin
        @mutex.synchronize do
          raise "shutting down" if @stopped
          @clients << client
        end
        client.get(uri.request_target, headers: HTTP::Headers{"User-Agent" => USER_AGENT}) do |res|
          raise "HTTP status #{res.status_code}" unless res.status_code == 200
          buf = IO::Memory.new
          IO.copy(res.body_io, buf, MAX_BODY_SIZE)
          buf.to_slice
        end
      ensure
        @mutex.synchronize { @clients.delete(client) }
        client.close
      end
      rates = file.ends_with?(".zip") ? FX.parse_hist_zip(body) : FX.parse_xml(String.new(body))
      raise "file contains no rates" if rates.empty?
      @d.store.save_ecb_rates(rates)
      result = LoadResult.new(rates)
      @d.store.set_setting(SETTING_HIST_UNTIL, Store.format_date(result.to)) if file == FILE_HIST
      result
    end

    # The latest day of an earlier complete history import; nil if
    # eurofxref-hist.zip was never loaded.
    private def hist_until : Time?
      FX.parse_day(@d.store.get_setting(SETTING_HIST_UNTIL))
    rescue
      nil
    end
  end
end
