require "http/server"
require "compress/zip"

module FXSpec
  # Answers requests to the ECB from testdata, keyed by file name.
  class FakeECB
    TESTDATA = "#{__DIR__}/testdata"

    getter files = {} of String => Bytes
    getter agents = [] of String
    property network_error = false
    property status : Int32? = nil
    @hits = Hash(String, Int32).new(0)
    @block : Channel(Nil)? = nil
    @mutex = Mutex.new

    def initialize
      {Zipfelkasse::FX::FILE_DAILY, Zipfelkasse::FX::FILE_90D}.each do |name|
        @files[name] = File.read("#{TESTDATA}/#{name}").to_slice
      end
      zip = IO::Memory.new
      Compress::Zip::Writer.open(zip) { |w| w.add("eurofxref-hist.csv", File.read("#{TESTDATA}/eurofxref-hist.csv")) }
      @files[Zipfelkasse::FX::FILE_HIST] = zip.to_slice
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

    # Requests hang until release.
    def block : Nil
      @block = Channel(Nil).new
    end

    def release : Nil
      @block.try { |b| b.close unless b.closed? }
    end

    def count(name : String) : Int32
      @mutex.synchronize { @hits[name] }
    end

    def total : Int32
      @mutex.synchronize { @hits.values.sum }
    end

    def hits : Hash(String, Int32)
      @mutex.synchronize { @hits.dup }
    end

    private def handle(ctx : HTTP::Server::Context) : Nil
      name = File.basename(ctx.request.path)
      @mutex.synchronize do
        @hits[name] += 1
        @agents << (ctx.request.headers["User-Agent"]? || "")
      end
      @block.try(&.receive?)
      # Closing the connection without an answer is a transport error for the client.
      return ctx.response.@io.close if network_error
      if body = @files[name]?
        ctx.response.status_code = status || 200
        ctx.response.write(body)
      else
        ctx.response.status_code = 404
      end
    end
  end
end
