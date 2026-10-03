require "http/client"
require "wait_group"

module Zipfelkasse
  BACKUP_KEEP = 7

  class App
    getter deps : Web::Deps
    getter fx : FX::Service
    getter recurring : Recurring::Service
    getter ynab : YNAB::Service
    getter handlers : Array(HTTP::Handler)
    # Background jobs: each runs in its own fiber until the stopper fires.
    getter jobs : Array(Proc(Stopper, Nil))

    # Kemal keeps routes, filters and handlers in global state: build one App
    # per process (specs reset it, see spec/web/web_helper.cr).
    def initialize(config : Config, store : Store)
      Web.location = config.location
      @deps = Web::Deps.new(config, store)
      @fx = FX::Service.new(@deps)
      @deps.fx = @fx
      @recurring = Recurring::Service.new(@deps)
      @ynab = YNAB::Service.new(@deps)
      @jobs = [
        ->(stopper : Stopper) { @fx.run(stopper) },
        ->(stopper : Stopper) { @recurring.run(stopper) },
        ->(stopper : Stopper) { @ynab.run(stopper) },
      ]
      configure_kemal
      mount_mcp
      Web::Gate.new(@deps).install
      Web.install_errors(store)
      register_routes
      Kemal.config.setup
      @handlers = Kemal.config.handlers.dup
    end

    private def configure_kemal : Nil
      Kemal.config.app_name = "Zipfelkasse"
      Kemal.config.env = "production"
      Kemal.config.logging = false
      Kemal.config.serve_static = false
      Kemal.config.max_request_body_size = Web::MAX_BODY_BYTES
      use Web::SecurityHeaders.new
      use Web::QuietDisconnects.new
    end

    private def mount_mcp : Nil
      if @deps.config.mcp_secret.empty?
        Log.info { "MCP disabled (MCP_SECRET is empty)" }
        return
      end
      use MCP::Mount.new(MCP::Server.new(@deps))
      Log.info(&.emit("MCP enabled", path: "/mcp/***", allowed: @deps.config.mcp_allowed_cidrs.map(&.to_s),
        proxies: @deps.config.trusted_proxies.map(&.to_s)))
    end

    private def register_routes : Nil
      Web::PublicController.new(@deps).register
      Web::WhoController.new(@deps).register
      Web::ExpensesController.new(@deps).register
      Web::BalancesController.new(@deps).register
      Web::ActivityController.new(@deps).register
      Web::SettingsController.new(@deps).register
      FX::Handlers.new(@deps, @fx).register
      Recurring::Handlers.new(@deps, @recurring).register
      YNAB::Handlers.new(@deps, @ynab).register
      Export::Handlers.new(@deps, Export::Service.new(@deps)).register
    end
  end

  module CLI
    # A failure the user can fix: it is printed without a backtrace.
    class Error < Exception
    end

    def self.run(args : Array(String)) : Int32
      cmd = args[0]? || "serve"
      case cmd
      when "serve"
        serve
      when "healthcheck"
        healthcheck(ENV["ZIPFELKASSE_ADDR"]?.try(&.strip) || "")
      else
        STDERR.print "unknown command #{cmd.inspect}\nusage: zipfelkasse [serve|healthcheck]\n"
        return 2
      end
      0
    rescue ex : Config::Error | Store::Error | Error | IO::Error
      STDERR.puts "zipfelkasse: #{messages(ex).join(": ")}"
      1
    end

    private def self.messages(ex : Exception) : Array(String)
      chain = [] of String
      while ex
        chain << (ex.message || ex.class.name)
        ex = ex.cause
      end
      chain
    end

    def self.serve : Nil
      config = Config.from_env
      Zipfelkasse.setup_logging
      store = Store.open(config.db_path)
      store.clock = -> { config.now }
      stopper = Stopper.new
      jobs = WaitGroup.new
      begin
        app = App.new(config, store)
        server = HTTP::Server.new(app.handlers)
        listen(server, config.addr)
        Kemal.config.server = server
        (app.jobs + [->(s : Stopper) { backup_loop(s, store, config) }]).each do |job|
          jobs.spawn { job.call(stopper) }
        end
        Process.on_terminate do
          if Kemal.config.running
            Log.info { "shutting down" }
            Kemal.stop
          else
            exit
          end
        end
        Log.info(&.emit("Zipfelkasse running", addr: config.addr, db: config.db_path, tz: config.location_name))
        Kemal.run(args: [] of String, trap_signal: false)
      ensure
        stopper.stop
        jobs.wait
        store.close
      end
    end

    # HTTP::Server has no timeouts of its own; without them a stalled
    # client holds its connection forever.
    class TimeoutServer < TCPServer
      def accept? : TCPSocket?
        super.try do |conn|
          conn.read_timeout = 30.seconds
          conn.write_timeout = 60.seconds
          conn
        end
      end
    end

    # ":8080" listens on all interfaces.
    private def self.listen(server : HTTP::Server, addr : String) : Nil
      host, _, port = addr.rpartition(':')
      host = host.lchop('[').rchop(']')
      port_num = port.to_i? || raise Error.new("cannot listen on #{addr}: missing port")
      if host.empty?
        begin
          server.bind(TimeoutServer.new("::", port_num))
        rescue Socket::Error
          server.bind(TimeoutServer.new("0.0.0.0", port_num))
        end
      else
        server.bind(TimeoutServer.new(host, port_num))
      end
    rescue ex : Socket::Error
      raise Error.new("cannot listen on #{addr}", cause: ex)
    end

    # One backup a day at 03:00 local time, on the configured clock.
    def self.backup_loop(stopper : Stopper, store : Store, config : Config) : Nil
      local = -> { config.now.in(config.location) }
      due = next_backup(local.call)
      while stopper.wait(due - local.call)
        begin
          path = store.backup(config.backup_dir, BACKUP_KEEP)
          Log.info(&.emit("backup written", path: path))
        rescue ex
          Log.error(exception: ex) { "backup failed" }
        end
        due = next_backup(due)
      end
    end

    def self.next_backup(now : Time) : Time
      t = Time.local(now.year, now.month, now.day, 3, 0, 0, location: now.location)
      return t if t > now
      n = now.shift(days: 1)
      Time.local(n.year, n.month, n.day, 3, 0, 0, location: now.location)
    end

    def self.healthcheck(addr : String) : Nil
      uri = URI.parse(health_url(addr))
      client = HTTP::Client.new(uri)
      client.connect_timeout = 3.seconds
      client.read_timeout = 3.seconds
      res = client.get(uri.path)
      raise Error.new("healthz: status #{res.status_code}") unless res.status_code == 200
    end

    def self.health_url(addr : String) : String
      addr = ":8080" if addr.empty?
      host, sep, port = addr.rpartition(':')
      raise Error.new("ZIPFELKASSE_ADDR #{addr.inspect}: missing port") if sep.empty?
      host = host.lchop('[').rchop(']')
      host = "127.0.0.1" if host.empty? || host == "0.0.0.0" || host == "::"
      host = "[#{host}]" if host.includes?(':')
      "http://#{host}:#{port}/healthz"
    end
  end
end
