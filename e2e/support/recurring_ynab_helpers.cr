module E2E
  # Helpers of recurring_ynab_spec.cr: entering expenses through the form,
  # reading the database and watching the YNAB fake.
  module RY
    extend self

    # The form of /ausgaben/neu for an expense in euros split equally.
    # *amount* is typed like a person would ("42,00").
    def form(title : String, date : String, amount : String, payer : Int64, whom : Array(Int64),
             category : Int64? = nil, reimbursement = false, notes = "") : Array({String, String})
      f = [
        {"titel", title}, {"datum", date}, {"kategorie", category.to_s}, {"waehrung", "EUR"},
        {"waehrung_andere", ""}, {"betrag", amount}, {"kurs", ""}, {"kurs_quelle", ""},
        {"bezahlt_von", payer.to_s}, {"notiz", notes}, {"aufteilung", "equal"},
      ]
      f << {"rueckzahlung", "1"} if reimbursement
      whom.each do |p|
        f << {"teil", p.to_s}
        f << {"wert_#{p}", ""}
      end
      f
    end

    # Creates an expense through the form and returns its ID.
    def create(world : World, user : User, form : Array({String, String})) : Int64
      r = user.post("/ausgaben/neu", form)
      raise "create #{form.to_h["titel"]}: #{r.status} #{r.error_message}" unless r.status == 303
      Database.count(world.app.db_path, "SELECT max(id) FROM expenses")
    end

    # Changes an expense through the form (same fields as when creating).
    def update(user : User, id : Int64, form : Array({String, String})) : Response
      r = user.post("/ausgaben/#{id}", form)
      raise "update #{id}: #{r.status} #{r.error_message}" unless r.status == 303
      r
    end

    def person(world : World, name : String) : Int64
      Database.open(world.app.db_path) do |db|
        db.query_one("SELECT id FROM participants WHERE name = ?", name, as: Int64)
      end
    end

    # Rows of a query on the database, every value as text.
    def rows(world : World, sql : String) : Array(Array(String))
      Database.open(world.app.db_path) do |db|
        out = [] of Array(String)
        db.query(sql) do |rs|
          rs.each do
            out << (0...rs.column_count).map { |_| v = rs.read; v.nil? ? "NULL" : v.to_s }
          end
        end
        out
      end
    end

    def column(world : World, sql : String) : Array(String)
      rows(world, sql).map(&.first)
    end

    def value(world : World, sql : String) : String
      rows(world, sql).first.first
    end

    # Waits until a count query gives *expected* (background work such as
    # the recurring job at startup).
    def wait_count(world : World, sql : String, expected : Int64) : Nil
      E2E.wait_until("#{sql} = #{expected}", 15.seconds) { Database.count(world.app.db_path, sql) == expected }
    end

    # Runs the block and returns the requests the YNAB fake received
    # meanwhile (and shortly after: the sync is debounced). Waits for
    # *expected* requests (if given) and then until the fake is idle.
    def ynab_calls(world : World, expected = 0, &) : Array(String)
      ynab = world.app.ynab
      mark = ynab.request_count
      yield
      if expected > 0
        E2E.wait_until("#{expected} YNAB requests", 15.seconds) { ynab.request_count >= mark + expected } rescue nil
      else
        sleep YNAB_QUIET
      end
      ynab.wait_idle
      ynab.requests[mark..].dup
    end

    # Text of the page's first <h1>.
    def h1(r : Response) : String
      r.doc.xpath_node("//h1").try(&.content.gsub(/\s+/, " ").strip) || ""
    end

    # Normalized text of every node matching *xpath*.
    def texts(r : Response, xpath : String) : Array(String)
      r.doc.xpath_nodes(xpath).map(&.content.gsub(/\s+/, " ").strip)
    end

    def attr(r : Response, xpath : String) : Array(String)
      r.doc.xpath_nodes(xpath).map(&.content)
    end

    # The transactions in the YNAB fake that are not deleted,
    # as [date, amount, payee, memo, category, cleared, approved, account].
    def live(world : World) : Array(Array(String | Int64 | Bool | Nil))
      world.app.ynab.live.map do |t|
        [t.date, t.amount, t.payee_name, t.memo, t.category_id, t.cleared, t.approved, t.account_id].map(&.as(String | Int64 | Bool | Nil))
      end
    end

    # [id, deleted] of every transaction the fake ever received.
    def txn_ids(world : World) : Array({String, Bool})
      world.app.ynab.all.map { |t| {t.id, t.deleted} }
    end

    # Texts of the activity log (newest first) as the activity page shows them.
    def activity(user : User) : Array(String)
      texts(user.get("/aktivitaet"), %(//*[contains(@class, "activity-main")]/div[1]))
    end

    # Options of a <select> as [value, text].
    def options(r : Response, select_id : String) : Array(Array(String))
      r.doc.xpath_nodes(%(//select[@id="#{select_id}"]//option)).map { |o| [o["value"], o.content.strip] }
    end

    def selected(r : Response, select_id : String) : Array(String)
      attr(r, %(//select[@id="#{select_id}"]//option[@selected]/@value))
    end
  end
end
