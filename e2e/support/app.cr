require "http/client"
require "socket"

module E2E
  # Saturday, 3 October 2026, 12:00 in Berlin.
  DEFAULT_NOW = "2026-10-03T10:00:00Z"

  MCP_SECRET    = "e2e-secret"
  YNAB_DELAY_MS = 50
  # Silence that proves a debounced YNAB run has come and gone.
  YNAB_QUIET = (YNAB_DELAY_MS * 5).milliseconds

  # A running Zipfelkasse binary with its own database directory.
  class App
    getter name : String
    getter bin : String
    getter dir : String
    getter port : Int32
    property now : String
    getter ynab : FakeYNAB
    getter log_path : String
    @process : Process?

    def initialize(@name, @bin, @dir, @ecb : FakeECB, @ynab : FakeYNAB, @now : String = DEFAULT_NOW,
                   @extra_env = {} of String => String)
      @port = App.free_port
      @log_path = File.join(@dir, "app.log")
    end

    def self.free_port : Int32
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.port
      server.close
      port
    end

    def db_path : String
      File.join(@dir, "zipfelkasse.db")
    end

    def base_url : String
      "http://127.0.0.1:#{@port}"
    end

    def host : String
      "127.0.0.1:#{@port}"
    end

    def env : Hash(String, String)
      {
        "ZIPFELKASSE_ADDR"               => host,
        "ZIPFELKASSE_DB"                 => db_path,
        "ZIPFELKASSE_BACKUP_DIR"         => File.join(@dir, "backups"),
        "TZ"                             => "Europe/Berlin",
        "MCP_SECRET"                     => MCP_SECRET,
        "MCP_ALLOWED_CIDRS"              => "127.0.0.1/32, ::1/128",
        "TRUSTED_PROXIES"                => "",
        "ZIPFELKASSE_TEST_NOW"           => @now,
        "ZIPFELKASSE_TEST_ECB_URL"       => @ecb.base_url,
        "ZIPFELKASSE_TEST_YNAB_URL"      => @ynab.base_url,
        "ZIPFELKASSE_TEST_YNAB_DELAY_MS" => YNAB_DELAY_MS.to_s,
      }.merge(@extra_env)
    end

    def start : self
      Dir.mkdir_p(@dir)
      log = File.open(@log_path, "a")
      @process = Process.new(@bin, ["serve"], env: env, output: log, error: log)
      E2E.wait_until("#{@name}: /healthz", 15.seconds) { healthy? }
      E2E.wait_until("#{@name}: ECB rates", 15.seconds) { ecb_rates_loaded? }
      self
    end

    # Runs `serve` until it exits by itself (a startup error) and returns the
    # exit status with everything it wrote.
    def run_to_exit(timeout = 10.seconds) : {Process::Status, String}
      Dir.mkdir_p(@dir)
      output = IO::Memory.new
      process = Process.new(@bin, ["serve"], env: env, output: output, error: output)
      exited = Channel(Process::Status).new
      spawn { exited.send(process.wait) }
      select
      when status = exited.receive
        {status, output.to_s}
      when timeout(timeout)
        process.terminate
        raise "#{@name}: still running after #{timeout}: #{output}"
      end
    end

    # Sends *signal*, waits for the exit and returns its status.
    def stop(signal : Signal = Signal::TERM) : Process::Status?
      process = @process || return
      @process = nil
      process.signal(signal) unless process.terminated?
      deadline = Time.instant + 15.seconds
      until process.terminated?
        process.signal(Signal::KILL) if Time.instant > deadline
        sleep 20.milliseconds
      end
      process.wait
    end

    def log : String
      File.exists?(@log_path) ? File.read(@log_path) : ""
    end

    def healthy? : Bool
      HTTP::Client.get("#{base_url}/healthz").status_code == 200
    rescue IO::Error | Socket::Error
      false
    end

    def ecb_rates_loaded? : Bool
      File.exists?(db_path) && Database.count(db_path, "SELECT count(*) FROM fx_rates WHERE source = 'ezb'") > 0
    rescue
      false
    end

    def healthcheck(addr = host) : Process::Status
      Process.run(@bin, ["healthcheck"], env: {"ZIPFELKASSE_ADDR" => addr})
    end
  end

  def self.wait_until(what : String, timeout : Time::Span, &) : Nil
    deadline = Time.instant + timeout
    until yield
      raise "timeout waiting for #{what}" if Time.instant > deadline
      sleep 20.milliseconds
    end
  end
end
