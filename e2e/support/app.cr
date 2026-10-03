require "http/client"
require "file_utils"
require "socket"

module E2E
  # Fixed "now" of the app under test (ZIPFELKASSE_TEST_NOW): Saturday,
  # 3 October 2026, 12:00 in Berlin.
  DEFAULT_NOW = "2026-10-03T10:00:00Z"

  MCP_SECRET = "e2e-geheim"

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
        "ZIPFELKASSE_TEST_YNAB_DELAY_MS" => "300",
      }.merge(@extra_env)
    end

    # Starts the binary and waits until /healthz answers and the startup
    # download of the ECB rates has landed in the database.
    def start(wait_for_rates = true) : self
      Dir.mkdir_p(@dir)
      log = File.open(@log_path, "a")
      @process = Process.new(@bin, ["serve"], env: env, output: log, error: log)
      E2E.wait_until("#{@name}: /healthz", 15.seconds) { healthy? }
      if wait_for_rates
        E2E.wait_until("#{@name}: ECB rates", 15.seconds) { ecb_rates_loaded? }
      end
      self
    end

    def running? : Bool
      if p = @process
        !p.terminated?
      else
        false
      end
    end

    def stop : Nil
      if p = @process
        unless p.terminated?
          p.signal(Signal::TERM)
          deadline = Time.instant + 15.seconds
          while !p.terminated? && Time.instant < deadline
            sleep 50.milliseconds
          end
          p.signal(Signal::KILL) unless p.terminated?
        end
        p.wait rescue nil
        @process = nil
      end
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
      return false unless File.exists?(db_path)
      Snapshot.count(db_path, "SELECT count(*) FROM fx_rates WHERE source = 'ezb'") > 0
    rescue
      false
    end

    # Runs `zipfelkasse healthcheck` and returns its exit status.
    def healthcheck(addr = host) : Process::Status
      Process.run(@bin, ["healthcheck"], env: {"ZIPFELKASSE_ADDR" => addr})
    end
  end

  def self.wait_until(what : String, timeout : Time::Span, &) : Nil
    deadline = Time.instant + timeout
    until yield
      raise "timeout waiting for #{what}" if Time.instant > deadline
      sleep 50.milliseconds
    end
  end

  def wait_until(what, timeout, &block : -> Bool)
    E2E.wait_until(what, timeout, &block)
  end
end
