require "json"
require "file_utils"

module E2E
  @@worlds_dir : String?

  def self.bin : String
    ENV["E2E_BIN"]? || raise "E2E_BIN is not set (path of the zipfelkasse binary to test)"
  end

  def self.worlds_dir : String
    @@worlds_dir ||= File.tempname("zipfelkasse-e2e", nil).tap { |dir| Dir.mkdir_p(dir) }
  end

  def self.keep_worlds? : Bool
    !ENV["E2E_KEEP"]?.nil?
  end

  # The binary under test with a fresh database, started on first use.
  class World
    getter name : String
    getter problems = [] of String
    @app : App?
    @ecb : FakeECB?
    @ynab : FakeYNAB?
    @dir : String?
    @log_lines = 0

    # *env*: extra environment for the app (e.g. MCP_ALLOWED_CIDRS).
    # *setup*: fills the database right after the first start.
    def initialize(@name : String, @now = DEFAULT_NOW, @env = {} of String => String,
                   @setup : Proc(World, Nil)? = nil)
    end

    def app : App
      @app || begin
        app = @app = new_app(@env)
        app.start
        @setup.try &.call(self)
        app
      end
    end

    def ecb : FakeECB
      @ecb ||= FakeECB.new
    end

    def ynab : FakeYNAB
      @ynab ||= FakeYNAB.new
    end

    # An app that is not started, to run it into a startup error.
    def new_app(env : Hash(String, String)) : App
      dir = @dir ||= File.join(E2E.worlds_dir, "#{@name.gsub(/[^a-z0-9]+/i, "-")}-#{Random.new.hex(3)}")
      App.new("app", E2E.bin, dir, ecb, ynab, @now, env)
    end

    # Restarts the app with another frozen "now" (same database, same
    # fakes); time-dependent behaviour can be stepped through this way.
    def restart(now : String) : Nil
      app.stop
      app.now = now
      app.start
    end

    def stop : Nil
      @app.try &.stop
      @ynab.try &.close
      @ecb.try &.close
      if (dir = @dir) && !E2E.keep_worlds?
        FileUtils.rm_rf(dir)
      end
    end

    def user : User
      User.new(self)
    end

    # Records a page with injected script elements or event handlers.
    def check_html(r : Response) : Nil
      return unless r.html? && !r.body.empty?
      r.injected_scripts.each { |s| @problems << "#{r.method} #{r.path} (#{r.status}): injected script: #{s}" }
    end

    # Waits for background work (YNAB sync).
    def settle : Nil
      app.ynab.wait_idle
    end

    # Forgets recorded problems (after a failed scenario).
    def discard : Nil
      @problems.clear
      new_log_errors
    end

    # Raises with the problems found since the last call: injected scripts
    # and errors in the app log, except those containing one of *errors*.
    def verify!(errors = [] of String) : Nil
      msgs = @problems.dup
      @problems.clear
      new_log_errors.each do |line|
        msgs << "app log: #{line}" unless errors.any? { |e| line.includes?(e) }
      end
      raise msgs.first(5).join("\n\n") + (msgs.size > 5 ? "\n\n… and #{msgs.size - 5} more" : "") unless msgs.empty?
    end

    private def new_log_errors : Array(String)
      return [] of String unless app = @app
      lines = app.log.lines
      fresh = lines[@log_lines..]
      @log_lines = lines.size
      fresh.select { |line| line.includes?("level=ERROR") || line.includes?("Unhandled exception") }
    end
  end

  # One person using the app.
  class User
    getter browser : Browser

    def initialize(@world : World)
      @browser = Browser.new(@world.app)
    end

    def get(path : String, headers = HTTP::Headers.new) : Response
      run(&.get(path, headers))
    end

    def head(path : String) : Response
      run(&.head(path))
    end

    def post(path : String, form = [] of {String, String}, headers = HTTP::Headers.new) : Response
      run(&.post(path, form, headers))
    end

    def post(path : String, form : Hash(String, String), headers = HTTP::Headers.new) : Response
      post(path, form.to_a, headers)
    end

    def tool(name : String, arguments = {} of String => JSON::Any) : Response
      run(&.tool(name, arguments))
    end

    def mcp(method : String, params = {} of String => JSON::Any) : Response
      run(&.mcp(method, params))
    end

    def run(& : Browser -> Response) : Response
      response = yield @browser
      @world.check_html(response)
      response
    end

    # Picks (or creates) the person this user acts as.
    def login(name : String) : Response
      who = get("/wer")
      id = who.doc.xpath_nodes(%(//form[@action="/wer"]//button[@name="id"])).find { |n| n.content.strip == name }.try(&.["value"])
      if id
        post("/wer", {"id" => id, "zurueck" => "/"})
      else
        post("/wer/neu", {"name" => name, "zurueck" => "/"})
      end
    end

    def me : Int64?
      browser.me
    end
  end
end
