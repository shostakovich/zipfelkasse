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

    # Kemal keeps routes, filters and handlers in global state: build one App
    # per process (specs reset it, see spec/support/test_server.cr).
    def initialize(config : Config, store : Store)
      Time::Location.local = config.location
      store.clock = -> { config.now }
      @deps = Web::Deps.new(config, store)
      @fx = FX::Service.new(@deps)
      @deps.fx = @fx
      @recurring = Recurring::Service.new(@deps)
      @ynab = YNAB::Service.new(@deps)
      configure_kemal
      Web.install_filters(store)
      mount_mcp
      Web.install_errors(store)
      register_routes
      Kemal.config.setup
      @handlers = Kemal.config.handlers.dup
    end

    def spawn_jobs(stopper : Stopper, wait_group : WaitGroup) : Nil
      wait_group.spawn { @fx.run(stopper) }
      wait_group.spawn { @recurring.run(stopper) }
      wait_group.spawn { @ynab.run(stopper) }
      wait_group.spawn { CLI.backup_loop(stopper, @deps.store, @deps.config) }
    end

    private def configure_kemal : Nil
      Kemal.config.env = "production"
      Kemal.config.logging = false
      Kemal.config.serve_static = false
      Kemal.config.max_request_body_size = Web::MAX_BODY_BYTES
      # Shorter than the 10 seconds `docker stop` waits before it kills the process.
      Kemal.config.shutdown_timeout = 5.seconds
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
      stopper = Stopper.new
      jobs = WaitGroup.new
      begin
        app = App.new(config, store)
        server = HTTP::Server.new(app.handlers)
        listen(server, config.addr)
        Kemal.config.server = server
        app.spawn_jobs(stopper, jobs)
        Log.info(&.emit("Zipfelkasse running", addr: config.addr, db: config.db_path, tz: config.location.name))
        Kemal.run(args: [] of String)
        Log.info { "shutting down" }
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

    def self.backup_loop(stopper : Stopper, store : Store, config : Config) : Nil
      due = Domain.next_at_hour(config.now.in(config.location), 3)
      while stopper.wait(due - config.now)
        begin
          path = store.backup(config.backup_dir, BACKUP_KEEP)
          Log.info(&.emit("backup written", path: path))
        rescue ex
          Log.error(exception: ex) { "backup failed" }
        end
        due = Domain.next_at_hour(due, 3)
      end
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
