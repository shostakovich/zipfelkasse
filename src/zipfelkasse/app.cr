require "http/client"
require "wait_group"

module Zipfelkasse
  # Number of nightly backups kept.
  BACKUP_KEEP = 7

  # The fully wired application: Deps, the services with background jobs and
  # the HTTP handler chain.
  class App
    getter d : Web::Deps
    getter handlers : Array(HTTP::Handler)
    # Background jobs: each runs in its own fiber until the stopper fires.
    getter jobs = [] of Proc(Stopper, Nil)

    def initialize(config : Config, store : Store, log : Logger)
      Web.location = config.location
      @d = Web::Deps.new(config, store, Web::Renderer.new(store), log)
      mcp = Web::MCPMount.new
      Web::Handlers.new(@d).register
      App.wire_features(self, @d, mcp)
      @handlers = Web.handlers(@d, mcp)
    end

    # Feature packages (fx, recurring, ynab, export, mcp) hook in here:
    # each defines `App.wire_<name>(app, d, mcp)`, which registers routes and
    # background jobs. Order like Go: fx first (it becomes d.fx), then
    # recurring, ynab, export, mcp.
    def self.wire_features(app : App, d : Web::Deps, mcp : Web::MCPMount) : Nil
      {% for name in %w(fx recurring ynab export mcp) %}
        {% if App.class.has_method?("wire_#{name.id}") %}
          App.wire_{{ name.id }}(app, d, mcp)
        {% end %}
      {% end %}
    end
  end

  module CLI
    def self.run(args : Array(String)) : Int32
      cmd = args[0]? || "serve"
      case cmd
      when "serve"
        serve
      when "healthcheck"
        healthcheck(ENV["ZIPFELKASSE_ADDR"]? || "")
      else
        STDERR.print "unknown command #{cmd.inspect}\nusage: zipfelkasse [serve|healthcheck]\n"
        return 2
      end
      0
    rescue ex
      STDERR.puts "zipfelkasse: #{ex.message}"
      1
    end

    def self.serve : Nil
      config = Config.from_env
      log = Logger.new(STDERR, location: config.location)
      store = begin
        Store.open(config.db_path)
      rescue ex
        raise Exception.new("database #{config.db_path}: #{ex.message}")
      end
      if now = config.frozen_now
        store.clock = -> { now }
      end
      begin
        app = App.new(config, store, log)
        server = HTTP::Server.new(app.handlers)
        listen(server, config.addr)

        stopper = Stopper.new
        jobs = WaitGroup.new
        (app.jobs + [->(s : Stopper) { backup_loop(s, store, config, log) }]).each do |job|
          jobs.spawn { job.call(stopper) }
        end

        shutdown = Channel(Nil).new
        {Signal::INT, Signal::TERM}.each { |sig| sig.trap { shutdown.close unless shutdown.closed? } }
        served = Channel(Exception?).new
        spawn do
          server.listen
          served.send(nil)
        rescue ex
          served.send(ex)
        end
        log.info("Zipfelkasse running", addr: config.addr, db: config.db_path, tz: config.location_name)

        select
        when ex = served.receive
          raise ex if ex
        when shutdown.receive?
          log.info("shutting down")
          server.close
        end
        stopper.stop
        jobs.wait
      ensure
        store.close
      end
    end

    # Binds like Go's net.Listen("tcp", addr): ":8080" listens on all
    # interfaces.
    private def self.listen(server : HTTP::Server, addr : String) : Nil
      host, _, port = addr.rpartition(':')
      host = host.lchop('[').rchop(']')
      port_num = port.to_i? || raise Exception.new("listen tcp #{addr}: address #{addr}: missing port in address")
      if host.empty?
        begin
          server.bind_tcp("::", port_num)
        rescue Socket::Error
          server.bind_tcp("0.0.0.0", port_num)
        end
      else
        server.bind_tcp(host, port_num)
      end
    rescue ex : Socket::Error
      raise Exception.new("listen tcp #{addr}: #{ex.message}")
    end

    # Writes a backup every night at 03:00 (local time) and keeps the last
    # BACKUP_KEEP.
    def self.backup_loop(stopper : Stopper, store : Store, config : Config, log : Logger) : Nil
      loop do
        now = Time.local(config.location)
        return unless stopper.wait(next_backup(now) - now)
        begin
          path = store.backup(config.backup_dir, BACKUP_KEEP)
          log.info("backup written", path: path)
        rescue ex
          log.error("backup failed", err: ex)
        end
      end
    end

    # The next 03:00 after now (in now's zone).
    def self.next_backup(now : Time) : Time
      t = Time.local(now.year, now.month, now.day, 3, 0, 0, location: now.location)
      return t if t > now
      n = now.shift(days: 1)
      Time.local(n.year, n.month, n.day, 3, 0, 0, location: now.location)
    end

    # GET /healthz on the local port.
    def self.healthcheck(addr : String) : Nil
      url = health_url(addr)
      uri = URI.parse(url)
      client = HTTP::Client.new(uri)
      client.connect_timeout = 3.seconds
      client.read_timeout = 3.seconds
      res = client.get(uri.path)
      raise Exception.new("healthz: status #{res.status_code}") unless res.status_code == 200
    end

    def self.health_url(addr : String) : String
      addr = ":8080" if addr.empty?
      host, sep, port = addr.rpartition(':')
      raise Exception.new("ZIPFELKASSE_ADDR #{addr.inspect}: address #{addr}: missing port in address") if sep.empty?
      host = host.lchop('[').rchop(']')
      host = "127.0.0.1" if host.empty? || host == "0.0.0.0" || host == "::"
      host = "[#{host}]" if host.includes?(':')
      "http://#{host}:#{port}/healthz"
    end
  end
end
