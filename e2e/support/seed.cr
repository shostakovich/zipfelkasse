require "json"

module E2E
  @@seeded_world : World?

  # The household of Seed, built once per process on first use and shared by
  # the read-only scenarios (they must not change it).
  def self.seeded_world : World
    @@seeded_world ||= World.new("seed", now: Seed::PHASE_A, setup: ->(world : World) do
      Seed.new(world).run
      world.verify!
    end)
  end

  # Builds a realistic household with every feature of the app, through the
  # same requests a browser (and the MCP client) sends: about two and a half
  # years of expenses in all split modes and several currencies, edits,
  # deletions, reimbursements, recurring rules, manual rates, archived people
  # and categories, YNAB and MCP entries. Names, titles and notes contain HTML
  # special characters, so escaping bugs show up everywhere.
  #
  # Deterministic: the same binary always produces the same database.
  class Seed
    GROUP_NAME = %(WG "Zipfel" & Co <3)

    PEOPLE = {
      anna: "Anna",
      ben:  "Ben",
      cleo: "Cleo <b>&amp;</b>",
      dora: %(Dora "D" O'Neil),
      emil: "Emil",
      gus:  "Gustav",
    }

    # title, category, min/max amount in euros
    TEMPLATES = [
      {"Rewe Einkauf", "Lebensmittel", 8, 95},
      {"Wochenmarkt", "Lebensmittel", 12, 40},
      {"Bäckerei Müller", "Lebensmittel", 3, 15},
      {"dm Drogerie & Co", "Lebensmittel", 5, 45},
      {"Pizza bei \"Luigi\"", "Restaurant", 25, 70},
      {"Döner <extra scharf>", "Restaurant", 9, 24},
      {"Café am Eck", "Restaurant", 6, 30},
      {"Putzmittel", "Haushalt", 4, 30},
      {"IKEA Regal", "Haushalt", 30, 260},
      {"Strom Abschlag", "Miete & Nebenkosten", 60, 95},
      {"Tankstelle", "Transport", 40, 90},
      {"Bahn-Tickets", "Transport", 19, 140},
      {"Kino: <Dune>", "Freizeit", 18, 40},
      {"Konzert 'Die Ärzte'", "Freizeit", 60, 180},
      {"Apotheke", "Gesundheit", 5, 40},
      {"Geburtstag Oma", "Geschenke", 20, 80},
      {"Tierfutter", "Haustier", 15, 60},
      {"Fachbuch & Kurs", "Bücher & Kurse", 25, 120},
      {"Alert-Test <script>alert(1)</script>", "<script>alert('kat')</script>", 1, 9},
      {"Sonstiges Zeug", "", 2, 25},
    ]

    NOTES = [
      "",
      "",
      "",
      "Quittung liegt im Ordner.",
      "Zeile 1\nZeile 2 mit <b>fett</b> & \"Zitat\"",
      "Rabatt 10 % – Danke, Ben!",
      "Tab\tgetrennt; Komma, Semikolon;",
      "=SUMME(A1:A3) und +49 123",
    ]

    getter people = {} of Symbol => Int64
    getter categories = {} of String => Int64
    getter expenses = [] of Int64
    # The form last posted for each expense, to edit it later.
    @forms = {} of Int64 => Array({String, String})
    @rng = Random.new(4711)

    def initialize(@world : World)
      @user = @world.user
    end

    # The seed runs in three phases with the clock frozen at these times; the
    # world must start at PHASE_A. It ends at DEFAULT_NOW.
    PHASE_A = "2026-09-20T07:15:00Z" # set up and enter the history
    PHASE_B = "2026-10-02T16:40:00Z" # corrections, settling up, MCP

    def run : self
      setup_people
      setup_categories
      settings
      history
      foreign_currencies
      recurring
      manual_rates
      @world.restart(PHASE_B)
      edits_and_deletions
      reimbursements
      archive
      mcp_entries
      @world.restart(DEFAULT_NOW)
      ynab
      @world.settle
      self
    end

    # --- helpers --------------------------------------------------------------

    private def expect(r : Response, status : Int32, what : String) : Response
      unless r.status == status
        raise "seed: #{what}: expected #{status}, got #{r.status} (#{r.error_message || r.location || r.body[0, 300]})"
      end
      r
    end

    private def as_person(key : Symbol) : Nil
      return if @user.me == @people[key]?
      expect(@user.post("/wer", {"id" => @people[key].to_s, "zurueck" => "/"}), 303, "login #{key}")
    end

    private def cents(euros : Int32 | Float64) : Int64
      (euros * 100).round.to_i64
    end

    private def amount(c : Int64) : String
      "#{c // 100},#{(c % 100).to_s.rjust(2, '0')}"
    end

    private def day(from : Time, to : Time) : Time
      from + @rng.rand(((to - from).days + 1).to_i).days
    end

    private def iso(t : Time) : String
      t.to_s("%Y-%m-%d")
    end

    # Active people on a date (Dora moves in in March 2025).
    private def household(date : Time) : Array(Symbol)
      date < Time.utc(2025, 3, 1) ? [:anna, :ben, :cleo] : [:anna, :ben, :cleo, :dora]
    end

    # Creates an expense through the form and returns its ID (the newest
    # row in the database).
    def create_expense(form : Array({String, String}), by who : Symbol) : Int64
      as_person(who)
      expect(@user.post("/ausgaben/neu", form), 303, "create #{form.to_h["titel"]?}")
      id = newest_expense_id
      @forms[id] = form
      @expenses << id
      id
    end

    private def newest_expense_id : Int64
      Database.count(@world.app.db_path, "SELECT max(id) FROM expenses")
    end

    def expense_form(title : String, date : Time, cents : Int64, payer : Symbol, whom : Array(Symbol),
                     category = "", mode = "equal", weights = {} of Symbol => String, currency = "EUR",
                     amount_text : String? = nil, rate = "", notes = "", other_currency = "") : Array({String, String})
      form = [
        {"titel", title}, {"datum", iso(date)}, {"kategorie", category.empty? ? "" : @categories[category].to_s},
        {"waehrung", currency}, {"waehrung_andere", other_currency}, {"betrag", amount_text || amount(cents)},
        {"kurs", rate}, {"kurs_quelle", rate.empty? ? "" : "manuell"},
        {"bezahlt_von", @people[payer].to_s}, {"notiz", notes}, {"aufteilung", mode},
      ]
      whom.each do |p|
        form << {"teil", @people[p].to_s}
        form << {"wert_#{@people[p]}", weights[p]? || ""}
      end
      form
    end

    # --- steps ------------------------------------------------------------------

    private def setup_people
      r = @user.get("/")
      expect(r, 303, "redirect to /wer")
      expect(@user.post("/wer/neu", {"name" => PEOPLE[:anna], "zurueck" => "/"}), 303, "create Anna")
      @people[:anna] = @user.me.not_nil!
      PEOPLE.each do |key, name|
        next if key == :anna
        expect(@user.post("/einstellungen/teilnehmer", {"name" => name}), 303, "add #{name}")
      end
      page = @user.get("/einstellungen/teilnehmer")
      PEOPLE.each do |key, name|
        input = page.doc.xpath_nodes(%(//li[starts-with(@id, "person-")])).find do |li|
          li.xpath_node(%(.//input[@name="name"])).try(&.["value"]) == name
        end
        raise "seed: person #{name} not listed" unless input
        @people[key] = input["id"].lchop("person-").to_i64
      end
      # A duplicate (case-insensitive) is refused.
      expect(@user.post("/einstellungen/teilnehmer", {"name" => "anna"}), 422, "duplicate person")
      # Gustav is renamed, archived and brought back.
      expect(@user.post("/einstellungen/teilnehmer/#{@people[:gus]}", {"name" => "Gustav  der   Große"}), 303, "rename Gustav")
      expect(@user.post("/einstellungen/teilnehmer/#{@people[:gus]}/archivieren"), 303, "archive Gustav")
      expect(@user.post("/einstellungen/teilnehmer/#{@people[:gus]}/reaktivieren"), 303, "reactivate Gustav")
    end

    private def setup_categories
      ["Haustier", "<script>alert('kat')</script>", "Bücher & Kurse", "Abos „Streaming“"].each do |name|
        expect(@user.post("/einstellungen/kategorien", {"name" => name}), 303, "add category #{name}")
      end
      expect(@user.post("/einstellungen/kategorien", {"name" => "  "}), 422, "empty category")
      page = @user.get("/einstellungen/kategorien")
      page.doc.xpath_nodes(%(//li[starts-with(@id, "kategorie-")])).each do |li|
        name = li.xpath_node(%(.//input[@name="name"])).try(&.["value"])
        @categories[name] = li["id"].lchop("kategorie-").to_i64 if name
      end
      expect(@user.post("/einstellungen/kategorien/#{@categories["Restaurant"]}/hoch"), 303, "move up")
      expect(@user.post("/einstellungen/kategorien/#{@categories["Transport"]}/runter"), 303, "move down")
      expect(@user.post("/einstellungen/kategorien/#{@categories["Sonstiges"]}", {"name" => "Sonstiges & Allerlei"}), 303, "rename")
      @categories["Sonstiges & Allerlei"] = @categories.delete("Sonstiges").not_nil!
    end

    private def settings
      expect(@user.post("/einstellungen", {"gruppenname" => ""}), 422, "empty group name")
      expect(@user.post("/einstellungen", {"gruppenname" => GROUP_NAME}), 303, "group name")
    end

    # About 600 everyday expenses from January 2024 to October 2026.
    private def history
      date = Time.utc(2024, 1, 8)
      last = Time.utc(2026, 10, 2)
      while date <= last
        n = @rng.rand(100) < 55 ? 1 : (@rng.rand(100) < 30 ? 2 : 0)
        n.times { everyday_expense(date) }
        date += 1.day
      end
    end

    private def everyday_expense(date : Time) : Nil
      title, category, lo, hi = TEMPLATES[@rng.rand(TEMPLATES.size)]
      house = household(date)
      payer = house[@rng.rand(house.size)]
      total = cents(lo + @rng.rand * (hi - lo))
      roll = @rng.rand(100)
      whom = house
      mode = "equal"
      weights = {} of Symbol => String
      if roll < 12
        whom = house.sample(2, @rng)
      elsif roll < 20
        mode = "shares"
        house.each { |p| weights[p] = (1 + @rng.rand(3)).to_s }
        weights[house.first] = "" if @rng.rand(2) == 0 # empty means 1 share
      elsif roll < 27
        mode = "percent"
        case house.size
        when 3 then weights = {house[0] => "50", house[1] => "33,33", house[2] => "16,67"}
        else        weights = {house[0] => "40", house[1] => "30", house[2] => "20", house[3] => "10"}
        end
      elsif roll < 33
        mode = "amount"
        rest = total
        house.each_with_index do |p, i|
          part = i == house.size - 1 ? rest : (total // house.size) - 7 * i
          rest -= part
          weights[p] = amount(part)
        end
      end
      notes = NOTES[@rng.rand(NOTES.size)]
      form = expense_form(title, date, total, payer, whom, category, mode, weights, notes: notes)
      create_expense(form, by: payer)
    end

    private def foreign_currencies
      # ECB rates (looked up by the app, the old ones from the history file).
      [
        {"Hotel New York", Time.utc(2024, 5, 18), "USD", "612,40", :ben, "Reisen"},
        {"Skipass", Time.utc(2025, 2, 9), "CHF", "238,00", :anna, "Reisen"},
        {"Ramen in Tokio", Time.utc(2025, 10, 4), "JPY", "4.850", :cleo, "Restaurant"},
        {"Surfkurs Bali", Time.utc(2026, 4, 3), "IDR", "1.250.000", :dora, "Reisen"},
        {"Pub-Abend", Time.utc(2026, 9, 26), "GBP", "86,50", :ben, "Restaurant"},
        {"Tempel-Tour", Time.utc(2026, 9, 30), "THB", "2.400", :anna, "Reisen"},
      ].each do |title, date, cur, amt, payer, cat|
        create_expense(expense_form(title, date, 0, payer, household(date), cat, currency: cur, amount_text: amt), by: payer)
      end
      # Amounts split in the foreign currency.
      d = Time.utc(2026, 8, 14)
      create_expense(expense_form("Mietwagen USA", d, 0, :anna, [:anna, :ben, :dora], "Transport", "amount",
        {:anna => "100,00", :ben => "60,50", :dora => "39,50"}, currency: "USD", amount_text: "200,00"), by: :anna)
      # A manual rate for a currency the ECB does not publish (3 decimals).
      create_expense(expense_form("Souk-Einkauf", Time.utc(2025, 11, 20), 0, :ben, [:ben, :cleo], "Reisen",
        currency: "", other_currency: "kwd", amount_text: "12,345", rate: "0,3312"), by: :ben)
      # No rate for that currency and none entered: refused.
      as_person(:anna)
      expect(@user.post("/ausgaben/neu", expense_form("Ohne Kurs", Time.utc(2026, 9, 1), 0, :anna, [:anna, :ben],
        currency: "", other_currency: "XAF", amount_text: "1000")), 422, "foreign without rate")
    end

    private def recurring
      rules = [
        {"Miete", Time.utc(2024, 2, 1), 145000_i64, :anna, "Miete & Nebenkosten", "monthly"},
        {"Streaming-Abo „Flix“", Time.utc(2025, 1, 31), 1799_i64, :cleo, "Abos „Streaming“", "monthly"},
        {"Gemüsekiste", Time.utc(2026, 7, 4), 2890_i64, :ben, "Lebensmittel", "weekly"},
        {"Haftpflicht <Versicherung>", Time.utc(2024, 2, 29), 8940_i64, :anna, "", "yearly"},
        {"Fitnessstudio", Time.utc(2025, 6, 15), 3500_i64, :dora, "Freizeit", "monthly"},
        {"Zeitung", Time.utc(2026, 3, 10), 2490_i64, :ben, "", "monthly"},
      ]
      ids = {} of String => Int64
      rules.each do |title, date, amt, payer, cat, freq|
        whom = title == "Fitnessstudio" ? [:dora] : household(date)
        id = create_expense(expense_form(title, date, amt, payer, whom, cat), by: payer)
        as_person(payer)
        expect(@user.get("/einstellungen/wiederkehrend/neu?ausgabe=#{id}"), 200, "recurring form")
        expect(@user.post("/einstellungen/wiederkehrend/neu", {"ausgabe" => id.to_s, "haeufigkeit" => freq}), 303, "recurring #{title}")
        ids[title] = rule_id_of(id)
      end
      expect(@user.post("/einstellungen/wiederkehrend/neu", {"ausgabe" => @expenses.first.to_s, "haeufigkeit" => "taeglich"}), 422, "bad frequency")
      # Pause the gym, end the newspaper (its expenses stay).
      expect(@user.post("/einstellungen/wiederkehrend/#{ids["Fitnessstudio"]}/pausieren"), 303, "pause")
      expect(@user.post("/einstellungen/wiederkehrend/#{ids["Zeitung"]}/loeschen"), 303, "delete rule")
      # The rent goes up: edit the newest instance and take it as template.
      newest_rent = Database.count(@world.app.db_path, "SELECT max(id) FROM expenses WHERE recurring_id = #{ids["Miete"]}")
      form = rent_form(newest_rent)
      as_person(:anna)
      expect(@user.post("/ausgaben/#{newest_rent}", form), 303, "raise rent")
      expect(@user.post("/einstellungen/wiederkehrend/#{ids["Miete"]}/vorlage"), 303, "template from rent")
      # Pause and resume the streaming subscription.
      expect(@user.post("/einstellungen/wiederkehrend/#{ids["Streaming-Abo „Flix“"]}/pausieren"), 303, "pause streaming")
      expect(@user.post("/einstellungen/wiederkehrend/#{ids["Streaming-Abo „Flix“"]}/fortsetzen"), 303, "resume streaming")
      expect(@user.get("/einstellungen/wiederkehrend"), 200, "recurring list")
    end

    private def rule_id_of(expense_id : Int64) : Int64
      Database.count(@world.app.db_path, "SELECT recurring_id FROM expenses WHERE id = #{expense_id}")
    end

    private def rent_form(id : Int64) : Array({String, String})
      date = Database.open(@world.app.db_path) { |db| db.scalar("SELECT date FROM expenses WHERE id = #{id}").as(String) }
      expense_form("Miete", Time.parse_utc(date, "%Y-%m-%d"), 152000, :anna, household(Time.utc(2026, 10, 1)), "Miete & Nebenkosten")
    end

    private def manual_rates
      as_person(:ben)
      expect(@user.post("/einstellungen/kurse", {"waehrung" => "kwd", "datum" => "2024-06-01", "kurs" => "0,3312"}), 303, "manual KWD")
      expect(@user.post("/einstellungen/kurse", {"waehrung" => "THB", "datum" => "01.09.2026", "kurs" => "39,5"}), 303, "manual THB")
      expect(@user.post("/einstellungen/kurse", {"waehrung" => "TRY", "datum" => "2026-01-01", "kurs" => "40"}), 303, "manual TRY")
      expect(@user.post("/einstellungen/kurse/loeschen", {"waehrung" => "TRY", "datum" => "2026-01-01"}), 303, "delete TRY")
      expect(@user.post("/einstellungen/kurse", {"waehrung" => "EUR", "datum" => "2026-01-01", "kurs" => "1"}), 422, "manual EUR")
      expect(@user.post("/einstellungen/kurse/aktualisieren"), 303, "refresh ECB")
      # An expense in THB now uses the manual rate.
      create_expense(expense_form("Massage", Time.utc(2026, 9, 12), 0, :dora, [:dora, :cleo], "Gesundheit",
        currency: "THB", amount_text: "1.200"), by: :dora)
    end

    private def edits_and_deletions
      candidates = @expenses.select { |id| @forms.has_key?(id) }.sample(60, @rng)
      candidates.first(45).each_with_index do |id, i|
        form = @forms[id].dup
        payer = form.to_h["bezahlt_von"]
        who = @people.key_for(payer.to_i64)
        idx = case i % 5
              when 0 then {"titel", form.to_h["titel"] + " (korrigiert)"}
              when 1 then {"betrag", amount(cents(5 + i))}
              when 2 then {"kategorie", @categories["Haushalt"].to_s}
              when 3 then {"notiz", "Nachtrag: <i>vergessen</i> & ergänzt"}
              else        {"datum", "2026-09-#{(i % 28 + 1).to_s.rjust(2, '0')}"}
              end
        form = form.map { |k, v| k == idx[0] ? {k, idx[1]} : {k, v} }
        as_person(who)
        r = @user.post("/ausgaben/#{id}", form)
        # Changing the amount of a split by amounts is refused; that is fine.
        expect(r, r.status == 422 ? 422 : 303, "edit #{id}")
        @forms[id] = form if r.status == 303
      end
      candidates.last(15).each do |id|
        expect(@user.post("/ausgaben/#{id}/loeschen"), 303, "delete #{id}")
      end
      expect(@user.post("/ausgaben/#{candidates.last}/loeschen"), 404, "delete twice")
      expect(@user.post("/ausgaben/#{candidates.last}", @forms[candidates.last]), 409, "edit deleted")
    end

    # Settles up a few times from the suggestions on the balances page.
    private def reimbursements
      3.times do |i|
        page = @user.get("/salden")
        link = page.doc.xpath_node(%(//a[contains(@href, "rueckzahlung=1")])).try(&.["href"])
        break unless link
        params = URI.parse(link).query_params
        from = params["von"].to_i64
        who = @people.key_for(from)
        as_person(who)
        expect(@user.get(link), 200, "reimbursement form")
        date = [Time.utc(2025, 3, 15), Time.utc(2025, 9, 15), Time.utc(2026, 3, 15)][i]
        form = [
          {"titel", "Rückzahlung"}, {"datum", iso(date)}, {"kategorie", ""}, {"waehrung", "EUR"},
          {"waehrung_andere", ""}, {"betrag", amount(params["betrag"].to_i64 // (i + 2))}, {"kurs", ""},
          {"kurs_quelle", ""}, {"bezahlt_von", from.to_s}, {"notiz", i == 0 ? "per PayPal" : ""},
          {"rueckzahlung", "1"}, {"aufteilung", "equal"}, {"teil", params["an"]}, {"wert_#{params["an"]}", ""},
        ]
        create_expense(form, by: who)
      end
    end

    private def archive
      # Emil never took part: archiving works. Health is archived as category.
      expect(@user.post("/einstellungen/teilnehmer/#{@people[:emil]}/archivieren"), 303, "archive Emil")
      expect(@user.post("/einstellungen/teilnehmer/#{@people[:ben]}/archivieren"), 422, "archive Ben with balance")
      expect(@user.post("/einstellungen/kategorien/#{@categories["Gesundheit"]}/archivieren"), 303, "archive category")
      expect(@user.post("/einstellungen/kategorien/#{@categories["Haustier"]}/archivieren"), 303, "archive Haustier")
      expect(@user.post("/einstellungen/kategorien/#{@categories["Haustier"]}/reaktivieren"), 303, "reactivate Haustier")
    end

    private def mcp_entries
      r = @user.tool("create_expense", {
        "title" => JSON::Any.new("Pizza <Lieferung>"), "amount" => JSON::Any.new("31.50"),
        "paid_by" => JSON::Any.new("ben"), "date" => JSON::Any.new("2026-10-02"),
        "category" => JSON::Any.new("restaurant"), "notes" => JSON::Any.new("per MCP"),
      })
      expect(r, 200, "mcp create_expense")
      @user.tool("create_expense", {
        "title" => JSON::Any.new("Gartenmöbel"), "amount" => JSON::Any.new("300"),
        "paid_by" => JSON::Any.new("Anna"), "date" => JSON::Any.new("2026-09-20"), "split" => JSON::Any.new("percent"),
        "weights" => JSON.parse(%({"Anna": 50, "Ben": "30", "Cleo <b>&amp;</b>": 20})),
      })
      @user.tool("create_expense", {
        "title" => JSON::Any.new("Souvenirs"), "amount" => JSON::Any.new("45.00"), "currency" => JSON::Any.new("usd"),
        "paid_by" => JSON::Any.new("Cleo <b>&amp;</b>"), "date" => JSON::Any.new("2026-09-27"),
        "participants" => JSON.parse(%(["Cleo <b>&amp;</b>", "Anna"])),
      })
      @user.tool("create_reimbursement", {
        "from" => JSON::Any.new("Ben"), "to" => JSON::Any.new("Anna"), "amount" => JSON::Any.new(20.0),
        "date" => JSON::Any.new("2026-10-01"), "notes" => JSON::Any.new("Überweisung"),
      })
      # A duplicate is refused.
      @user.tool("create_expense", {
        "title" => JSON::Any.new("pizza <lieferung>"), "amount" => JSON::Any.new("31.5"),
        "paid_by" => JSON::Any.new("Ben"), "date" => JSON::Any.new("2026-10-02"),
      })
      @expenses.concat(Database.open(@world.app.db_path) { |db| db.query_all("SELECT id FROM expenses WHERE id > #{@expenses.max}", as: Int64) })
    end

    private def ynab
      as_person(:anna)
      expect(@user.post("/einstellungen/ynab/token", {"token" => "wrong"}), 422, "bad token")
      expect(@user.post("/einstellungen/ynab/token", {"token" => FakeYNAB::TOKEN}), 303, "token")
      expect(@user.get("/einstellungen/ynab"), 200, "ynab page")
      expect(@user.post("/einstellungen/ynab/konto", {"ziel" => "#{FakeYNAB::PLAN}|#{FakeYNAB::ACCOUNT}", "start" => "2026-06-01"}), 303, "ynab target")
      expect(@user.post("/einstellungen/ynab/kategorien", {
        "kat-#{@categories["Lebensmittel"]}"        => "c-food",
        "kat-#{@categories["Restaurant"]}"          => "c-out",
        "kat-#{@categories["Miete & Nebenkosten"]}" => "c-rent",
        "kat-#{@categories["Freizeit"]}"            => "c-fun",
      }), 303, "ynab categories")
      expect(@user.post("/einstellungen/ynab/sync"), 303, "ynab sync")
      @world.settle
      # Ben uses a token of another YNAB user and stops halfway.
      as_person(:ben)
      expect(@user.post("/einstellungen/ynab/token", {"token" => FakeYNAB::OTHER_TOKEN}), 303, "ben token")
      expect(@user.get("/einstellungen/ynab"), 200, "ben ynab page")
      # Changes after the first sync are synced too.
      as_person(:anna)
      id = @expenses.find { |e| (f = @forms[e]?) && f.to_h["datum"] >= "2026-07-01" && f.to_h["rueckzahlung"]?.nil? }
      if id
        form = @forms[id].map { |k, v| k == "titel" ? {k, v + " – YNAB"} : {k, v} }
        @user.post("/ausgaben/#{id}", form)
      end
      @world.settle
      expect(@user.get("/einstellungen/ynab"), 200, "ynab status")
    end
  end
end
