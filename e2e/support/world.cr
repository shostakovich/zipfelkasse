require "json"

module E2E
  def self.bin : String
    ENV["E2E_BIN"]? || raise "E2E_BIN is not set (path of the zipfelkasse binary to test)"
  end

  def self.data_dir : String
    File.expand_path("../data", __DIR__)
  end

  # The binary under test with a fresh database, started on first use.
  class World
    getter name : String
    getter problems = [] of String
    @app : App?
    @ecb : FakeECB?
    @dir : String?

    # *seed_db*: start from a copy of this database instead of an empty one.
    # *env*: extra environment for the app (e.g. MCP_ALLOWED_CIDRS).
    def initialize(@name : String, @seed_db : String? = nil, @now = DEFAULT_NOW,
                   @env = {} of String => String, @wait_for_rates = true)
    end

    def app : App
      @app ||= start
    end

    def ecb : FakeECB
      @ecb ||= FakeECB.new
    end

    private def start : App
      dir = @dir = File.join(E2E.data_dir, "worlds", "#{@name.gsub(/[^a-z0-9]+/i, "-")}-#{Random.new.hex(3)}")
      app = App.new("app", E2E.bin, dir, ecb, FakeYNAB.new, @now, @env)
      if seed = @seed_db
        Dir.mkdir_p(app.dir)
        File.copy(seed, app.db_path)
        ynab_state = World.ynab_state_path(seed)
        app.ynab.load(File.read(ynab_state)) if File.exists?(ynab_state)
      end
      app.start(@wait_for_rates)
      # A copied database may start a YNAB sync right away; let it finish.
      app.ynab.wait_idle if @seed_db
      app
    end

    # Where the state of the YNAB fake belonging to a database is kept.
    def self.ynab_state_path(db : String) : String
      db.sub(/\.db$/, "") + ".ynab.json"
    end

    # Saves the database (and its YNAB fake) for later worlds.
    def save(path : String) : Nil
      Snapshot.copy(app.db_path, to: path)
      File.write(World.ynab_state_path(path), app.ynab.dump)
    end

    # Restarts the app with another frozen "now" (same database, same
    # fakes); time-dependent behaviour can be stepped through this way.
    def restart(now : String) : Nil
      app.stop
      app.now = now
      app.start
    end

    # Stops everything; the database and log are removed unless E2E_KEEP is
    # set.
    def stop : Nil
      @app.try do |a|
        a.stop
        a.ynab.close
      end
      @ecb.try &.close
      if (dir = @dir) && !ENV["E2E_KEEP"]?
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
    end

    # Raises with the problems found since the last call.
    def verify! : Nil
      msgs = @problems.dup
      @problems.clear
      raise msgs.first(5).join("\n\n") + (msgs.size > 5 ? "\n\n… and #{msgs.size - 5} more" : "") unless msgs.empty?
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
