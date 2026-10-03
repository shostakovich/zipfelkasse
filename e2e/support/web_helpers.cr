require "http/client"
require "uri"
require "digest/sha256"

module E2E
  # Helpers for the scenarios of the core web app (e2e/web_spec.cr).
  module Web
    FORM_CT = "application/x-www-form-urlencoded"

    SECURITY_HEADERS = {
      "X-Content-Type-Options"  => "nosniff",
      "Referrer-Policy"         => "same-origin",
      "X-Frame-Options"         => "DENY",
      "Content-Security-Policy" => "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'",
    }

    def self.form_body(form : Enumerable({String, String})) : String
      URI::Params.build { |p| form.each { |k, v| p.add(k, v) } }
    end

    # Sends a request with exactly the given headers (no Origin or
    # Sec-Fetch-Site added); the block gets the app to build per-app headers.
    def self.raw(user : User, method : String, path : String, body : String? = nil, &headers : App -> HTTP::Headers) : Response
      user.run { |b| b.request(method, path, headers.call(b.app), body) }
    end

    # POSTs a large body, with Content-Length or chunked, and reads the
    # answer while the body is still being written: a server may answer (and
    # close the connection) before it has read the body.
    def self.post_large(user : User, path : String, body : String, chunked = false,
                        content_type = "application/x-www-form-urlencoded", extra = HTTP::Headers.new) : Response
      user.run do |b|
        headers = HTTP::Headers{"Host" => b.app.host, "Content-Type" => content_type}
        headers.merge!(extra)
        b.jar.add_request_headers(headers)
        if chunked
          headers["Transfer-Encoding"] = "chunked"
        else
          headers["Content-Length"] = body.bytesize.to_s
        end
        socket = TCPSocket.new("127.0.0.1", b.app.port)
        socket.read_timeout = 30.seconds
        begin
          socket << "POST " << path << " HTTP/1.1\r\n"
          headers.each { |k, vs| vs.each { |v| socket << k << ": " << v << "\r\n" } }
          socket << "\r\n"
          socket.flush
          spawn do
            if chunked
              bytes = body.to_slice
              (0...bytes.size).step(64 * 1024) do |pos|
                part = bytes[pos, Math.min(64 * 1024, bytes.size - pos)]
                socket << part.size.to_s(16) << "\r\n"
                socket.write(part)
                socket << "\r\n"
              end
              socket << "0\r\n\r\n"
            else
              socket << body
            end
            socket.flush
          rescue IO::Error
            # the server stopped reading
          end
          res = HTTP::Client::Response.from_io(socket)
          Response.new("POST", path, res.status_code, res.headers, res.body? || "", res.cookies)
        ensure
          socket.close rescue nil
        end
      end
    end

    # Puts a cookie into the user's jar.
    def self.set_cookie(user : User, name : String, value : String) : Nil
      user.browser.jar << HTTP::Cookie.new(name, value)
    end

    # Content of an element, whitespace collapsed.
    def self.squish(s : String) : String
      s.gsub(/\s+/, " ").strip
    end

    def self.texts(r : Response, xpath : String) : Array(String)
      r.doc.xpath_nodes(xpath).map { |n| squish(n.content) }
    end

    def self.text_of(r : Response, xpath : String) : String?
      r.doc.xpath_node(xpath).try { |n| squish(n.content) }
    end

    def self.attr(r : Response, xpath : String, name : String) : String?
      r.doc.xpath_node(xpath).try(&.[name]?)
    end

    # Value of a form input.
    def self.input(r : Response, name : String) : String?
      attr(r, %(//input[@name="#{name}"]), "value")
    end

    # Value of the selected option of a select ("" if the empty option is
    # selected, nil if none is).
    def self.selected(r : Response, name : String) : String?
      attr(r, %(//select[@name="#{name}"]/option[@selected]), "value")
    end

    # IDs of the checked "teil" boxes of the expense form.
    def self.checked(r : Response) : Array(String)
      r.doc.xpath_nodes(%(//input[@name="teil"][@checked])).map(&.["value"])
    end

    # The document title (`<title>`).
    def self.page_title(r : Response) : String?
      text_of(r, "//title")
    end

    # The main heading (on error pages: the message).
    def self.h1(r : Response) : String?
      text_of(r, "//main//h1")
    end

    # Labels of the period groups (home and activity).
    def self.groups(r : Response) : Array(String)
      r.doc.xpath_nodes(%(//*[@data-group])).map(&.["data-group"])
    end

    # The navigation tab marked as current.
    def self.current_tab(r : Response) : String?
      attr(r, %(//nav[@aria-label="Hauptnavigation"]/a[@aria-current="page"]), "href")
    end

    def self.nav?(r : Response) : Bool
      !r.doc.xpath_node(%(//nav[@aria-label="Hauptnavigation"])).nil?
    end

    def self.whoami(r : Response) : String?
      text_of(r, %(//p[@class="whoami"]/strong))
    end

    # The flash message shown on the page (role=status).
    def self.shown_flash(r : Response) : String?
      text_of(r, %(//*[@role="status"]))
    end

    def self.cookie(r : Response, name : String) : HTTP::Cookie?
      r.cookies[name]?
    end

    def self.sha10(body : String) : String
      Digest::SHA256.hexdigest(body)[0, 10]
    end

    # A form of the expense page with sensible defaults; *teil* are the
    # people involved, *werte* their values.
    def self.expense(titel = "Einkauf", betrag = "30,00", bezahlt_von : Int64 | String = 1, teil = [] of Int64,
                     datum = "2026-10-01", kategorie = "", waehrung = "EUR", waehrung_andere = "", kurs = "",
                     kurs_quelle = "", notiz = "", aufteilung = "equal", werte = {} of Int64 => String,
                     rueckzahlung = false) : Array({String, String})
      form = [
        {"titel", titel}, {"datum", datum}, {"kategorie", kategorie}, {"waehrung", waehrung},
        {"waehrung_andere", waehrung_andere}, {"betrag", betrag}, {"kurs", kurs}, {"kurs_quelle", kurs_quelle},
        {"bezahlt_von", bezahlt_von.to_s}, {"notiz", notiz}, {"aufteilung", aufteilung},
      ]
      form << {"rueckzahlung", "1"} if rueckzahlung
      teil.each { |id| form << {"teil", id.to_s} }
      werte.each { |id, v| form << {"wert_#{id}", v} }
      form
    end

    # Shares of an expense in the primary database: participant → cents.
    def self.shares(world : World, expense_id : Int64) : Hash(Int64, Int64)
      Snapshot.open(world.app.db_path) do |db|
        db.query_all("SELECT participant_id, amount_cents FROM expense_shares WHERE expense_id = ? ORDER BY participant_id",
          expense_id, as: {Int64, Int64}).to_h
      end
    end

    def self.count(world : World, sql : String) : Int64
      Snapshot.count(world.app.db_path, sql)
    end

    def self.newest_expense(world : World) : Int64
      count(world, "SELECT coalesce(max(id), 0) FROM expenses")
    end

    # The "text" of every activity entry in the primary database, oldest first
    # (entries without one, e.g. expense changes, are skipped).
    def self.activity_texts(world : World) : Array(String)
      Snapshot.open(world.app.db_path) do |db|
        db.query_all("SELECT details_json FROM activity ORDER BY id", as: String).compact_map do |j|
          JSON.parse(j)["text"]?.try(&.as_s)
        end
      end
    end
  end
end
