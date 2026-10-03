require "http/client"
require "set"

module Zipfelkasse
  # The requests of YNAB and ECB; stopping aborts them and refuses new ones, so
  # a shutdown does not wait for a slow server. No proxy, no redirects.
  class OutboundHTTP
    class Stopped < Exception
      def initialize
        super("shutting down")
      end
    end

    record Response, status : Int32, headers : HTTP::Headers, body : Bytes

    getter? stopped = false
    @open = Set(HTTP::Client).new

    def initialize(@timeout : Time::Span, @max_body : Int32)
    end

    def request(method : String, url : String, headers : HTTP::Headers, body : String? = nil) : Response
      raise Stopped.new if @stopped
      uri = URI.parse(url)
      client = HTTP::Client.new(uri)
      client.connect_timeout = client.read_timeout = client.write_timeout = @timeout
      @open << client
      begin
        client.exec(method, uri.request_target, headers, body) do |res|
          buffer = IO::Memory.new
          IO.copy(res.body_io, buffer, @max_body)
          Response.new(res.status_code, res.headers, buffer.to_slice)
        end
      ensure
        @open.delete(client)
        client.close
      end
    end

    def stop : Nil
      @stopped = true
      @open.each(&.close)
    end
  end
end
