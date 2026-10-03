require "json"

module E2E
  # The binaries under test. E2E_BIN is checked by the suite's assertions;
  # with E2E_REF_BIN set, every request also goes to the reference binary
  # and both answers (and databases) must be equivalent.
  def self.bin : String
    ENV["E2E_BIN"]? || raise "E2E_BIN is not set (path of the zipfelkasse binary to test)"
  end

  def self.ref_bin : String?
    ENV["E2E_REF_BIN"]?.presence
  end

  def self.data_dir : String
    File.expand_path("../data", __DIR__)
  end

  # A set of apps (the binary under test, optionally the reference) with
  # fresh databases. Everything a scenario does goes to all of them.
  class World
    getter name : String
    getter differences = [] of String
    getter problems = [] of String
    @apps : Array(App)?
    @ecb : FakeECB?
    @dir : String?

    # *seed_db*: start from a copy of this database instead of an empty one.
    # *env*: extra environment for the apps (e.g. MCP_ALLOWED_CIDRS).
    # *bins*: the binaries to run; default E2E_BIN and, if set, E2E_REF_BIN.
    def initialize(@name : String, @seed_db : String? = nil, @now = DEFAULT_NOW,
                   @env = {} of String => String, @bins : Array({String, String})? = nil)
    end

    def apps : Array(App)
      @apps ||= start
    end

    def ecb : FakeECB
      @ecb ||= FakeECB.new
    end

    def primary : App
      apps.first
    end

    def diff_mode? : Bool
      apps.size > 1
    end

    private def start : Array(App)
      bins = @bins || begin
        b = [{"app", E2E.bin}]
        if ref = E2E.ref_bin
          b << {"ref", ref}
        end
        b
      end
      dir = @dir = File.join(E2E.data_dir, "worlds", "#{@name.gsub(/[^a-z0-9]+/i, "-")}-#{Random.new.hex(3)}")
      apps = bins.map do |label, bin|
        app = App.new(label, bin, File.join(dir, label), ecb, FakeYNAB.new, @now, @env)
        if seed = @seed_db
          Dir.mkdir_p(app.dir)
          File.copy(seed, app.db_path)
          ynab_state = World.ynab_state_path(seed)
          app.ynab.load(File.read(ynab_state)) if File.exists?(ynab_state)
        end
        app.start
      end
      # A copied database may start a YNAB sync right away; let it finish.
      apps.each(&.ynab.wait_idle) if @seed_db
      apps
    end

    # Where the state of the YNAB fake belonging to a database is kept.
    def self.ynab_state_path(db : String) : String
      db.sub(/\.db$/, "") + ".ynab.json"
    end

    # Saves the primary database (and its YNAB fake) for later worlds.
    def save(path : String) : Nil
      Snapshot.copy(primary.db_path, to: path)
      File.write(World.ynab_state_path(path), primary.ynab.dump)
    end

    # Restarts every app with another frozen "now" (same databases, same
    # fakes); time-dependent behaviour can be stepped through this way.
    def restart(now : String) : Nil
      apps.each do |a|
        a.stop
        a.now = now
        a.start
      end
    end

    # Stops everything; the databases and logs are removed unless E2E_KEEP
    # is set.
    def stop : Nil
      @apps.try &.each do |a|
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

    # Records that the apps answered differently.
    def differ(where : String, detail : String) : Nil
      @differences << "#{where}\n#{detail}"
    end

    # Records an assertion-independent defect (e.g. injected script).
    def problem(where : String, detail : String) : Nil
      @problems << "#{where}: #{detail}"
    end

    # Compares the answers of all apps to the same request.
    def compare(responses : Array(Response)) : Nil
      responses.each { |r| check_html(r) }
      return if responses.size < 2
      a, b = responses[0], responses[1]
      where = "#{a.method} #{a.path}"
      Compare.responses(a, b).each { |d| differ(where, d) }
    end

    private def check_html(r : Response) : Nil
      return unless r.html? && !r.body.empty?
      DOM.injected_scripts(r.doc).each { |s| problem("#{r.method} #{r.path} (#{r.status})", "injected script: #{s}") }
    end

    # Waits for background work (YNAB sync) of all apps.
    def settle : Nil
      apps.each(&.ynab.wait_idle)
    end

    # Forgets recorded differences (after a failed scenario).
    def discard : Nil
      @problems.clear
      @differences.clear
    end

    # Compares databases and fake YNAB state; raises with every difference
    # and problem found since the last call.
    def verify!(label = "") : Nil
      if diff_mode?
        settle
        a, b = apps[0], apps[1]
        if (sa = Snapshot.schema(a.db_path)) != (sb = Snapshot.schema(b.db_path))
          differ("schema #{label}", Compare.text_diff(sa, sb))
        end
        if (ca = Snapshot.content(a.db_path)) != (cb = Snapshot.content(b.db_path))
          differ("database #{label}", Compare.text_diff(ca, cb))
        end
        ya, yb = a.ynab.all.to_json, b.ynab.all.to_json
        differ("YNAB fake #{label}", Compare.text_diff(ya, yb)) if ya != yb
      end
      msgs = @problems + @differences
      @problems.clear
      @differences.clear
      raise msgs.first(5).join("\n\n") + (msgs.size > 5 ? "\n\n… and #{msgs.size - 5} more" : "") unless msgs.empty?
    end
  end

  # One person using the apps; every request goes to every app.
  class User
    getter browsers : Array(Browser)

    def initialize(@world : World)
      @browsers = @world.apps.map { |a| Browser.new(a) }
    end

    def browser : Browser
      @browsers.first
    end

    def get(path : String, headers = HTTP::Headers.new) : Response
      run { |b| b.get(path, headers) }
    end

    def head(path : String) : Response
      run(&.head(path))
    end

    def post(path : String, form = [] of {String, String}, headers = HTTP::Headers.new) : Response
      run { |b| b.post(path, form, headers) }
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
      responses = @browsers.map { |b| yield b }
      @world.compare(responses)
      responses.first
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
