require "./e2e_helper"

private alias RY = E2E::RY

# Recurring expenses (/einstellungen/wiederkehrend): rules made from an
# expense, catch-up of missed occurrences, end-of-month and leap-day
# arithmetic, pausing, templates, deletion and the job at startup.
describe "Recurring expenses" do
  world = E2E::World.new("recurring")
  after_all { world.stop }

  list = "/einstellungen/wiederkehrend"
  neu = "/einstellungen/wiederkehrend/neu"
  ids = {} of String => Int64   # expenses
  rules = {} of String => Int64 # recurring rules
  anna = ben = 0_i64

  rule_of = ->(expense : Int64) { RY.value(world, "SELECT recurring_id FROM expenses WHERE id = #{expense}").to_i64 }
  dates_of = ->(rule : Int64) { RY.column(world, "SELECT date FROM expenses WHERE recurring_id = #{rule} AND deleted_at IS NULL ORDER BY date") }
  rule_row = ->(rule : Int64) { RY.rows(world, "SELECT frequency, start_date, next_date, active FROM recurring WHERE id = #{rule}").first? }
  labels = ->(r : E2E::Response) { RY.texts(r, %(//label[input[@name="haeufigkeit"]])) }
  checked = ->(r : E2E::Response) { RY.attr(r, %(//input[@name="haeufigkeit"][@checked]/@value)) }

  scenario "list and form without an expense, unknown expenses and rules", world do
    user = world.user
    user.login("Anna").status.should eq 303
    user.post("/einstellungen/teilnehmer", {"name" => "Ben"}).status.should eq 303
    anna = RY.person(world, "Anna")
    ben = RY.person(world, "Ben")

    r = user.get(list)
    r.status.should eq 200
    RY.h1(r).should eq "Wiederkehrende Ausgaben"
    r.text.should contain "Noch keine wiederkehrenden Ausgaben."
    r.doc.xpath_nodes("//table").size.should eq 0

    r = user.get(neu)
    r.status.should eq 200
    RY.h1(r).should eq "Wiederkehrende Ausgabe anlegen"
    r.text.should contain "Öffne zuerst die Ausgabe, die sich wiederholen soll, und wähle dort „Als wiederkehrend einrichten“."
    RY.attr(r, %(//a[normalize-space()="Zu den Ausgaben"]/@href)).should eq ["/"]
    r.doc.xpath_nodes(%(//input[@name="haeufigkeit"])).size.should eq 0
    user.get(neu + "?ausgabe=").status.should eq 200

    ["abc", "0", "-1", "999", "1.5"].each do |q|
      r = user.get("#{neu}?ausgabe=#{q}")
      r.status.should eq 404
      RY.h1(r).should eq "Ausgabe nicht gefunden."
    end
    r = user.post(neu, {"ausgabe" => "999", "haeufigkeit" => "monthly"})
    r.status.should eq 404
    RY.h1(r).should eq "Ausgabe nicht gefunden."
    user.post(neu, {"haeufigkeit" => "monthly"}).status.should eq 404

    %w(pausieren fortsetzen vorlage loeschen).each do |action|
      %w(999 0 -3 abc).each do |id|
        r = user.post("#{list}/#{id}/#{action}")
        r.status.should eq 404
        RY.h1(r).should eq "Wiederkehrende Ausgabe nicht gefunden."
      end
    end
    E2E::Database.count(world.app.db_path, "SELECT count(*) FROM recurring").should eq 0
  end

  scenario "monthly rule from an old expense: preview, validation, catch-up with end-of-month clamping", world do
    user = world.user
    user.login("Anna")
    miete = ids["miete"] = RY.create(world, user, RY.form("Miete", "2026-01-31", "1000,00", anna, [anna, ben], category: 4, notes: "Warm"))

    r = user.get("#{neu}?ausgabe=#{miete}")
    r.status.should eq 200
    summary = r.doc.xpath_nodes("//tr[th]").to_h { |tr| {tr.xpath_node("th").not_nil!.content.strip, tr.xpath_node("td").not_nil!.content.gsub(/\s+/, " ").strip} }
    summary.should eq({
      "Titel" => "Miete", "Betrag" => "1.000,00 €", "Bezahlt von" => "Anna", "Kategorie" => "Miete & Nebenkosten",
      "Aufteilung" => "Gleichmäßig", "Notiz" => "Warm", "Erster Termin" => "31.01.2026",
    })
    labels.call(r).should eq [
      "Wöchentlich – nächster Termin 07.02.2026; 35 verpasste Termine werden sofort eingetragen",
      "Monatlich – nächster Termin 28.02.2026; 8 verpasste Termine werden sofort eingetragen",
      "Jährlich – nächster Termin 31.01.2027",
    ]
    checked.call(r).should eq ["monthly"]
    RY.attr(r, %(//form[@action="#{neu}"]//input[@name="ausgabe"]/@value)).should eq [miete.to_s]
    RY.attr(r, %(//a[normalize-space()="Abbrechen"]/@href)).should eq ["/ausgaben/#{miete}"]

    # Invalid frequencies re-render the form with the submitted choice.
    {"taeglich", "", "Monthly"}.each do |freq|
      r = user.post(neu, {"ausgabe" => miete.to_s, "haeufigkeit" => freq})
      r.status.should eq 422
      r.error_message.should eq "Bitte eine Häufigkeit wählen."
      checked.call(r).should be_empty
      labels.call(r).size.should eq 3
    end
    r = user.post(neu, {"ausgabe" => miete.to_s})
    r.status.should eq 422
    r.error_message.should eq "Bitte eine Häufigkeit wählen."

    r = user.post(neu, {"ausgabe" => miete.to_s, "haeufigkeit" => "monthly"})
    r.status.should eq 303
    r.location.should eq list
    r.flash.should eq "„Miete“ wiederholt sich jetzt monatlich. 8 Ausgaben nachgetragen."
    rule = rules["miete"] = rule_of.call(miete)
    dates_of.call(rule).should eq %w(2026-01-31 2026-02-28 2026-03-31 2026-04-30 2026-05-31 2026-06-30 2026-07-31 2026-08-31 2026-09-30)
    rule_row.call(rule).should eq ["monthly", "2026-01-31", "2026-10-31", "1"]
    RY.value(world, "SELECT created_by FROM recurring WHERE id = #{rule}").should eq anna.to_s
    # Every instance is a copy of the template, entered by the system.
    RY.rows(world, "SELECT DISTINCT title, amount_cents, paid_by, category_id, notes, split_mode FROM expenses WHERE recurring_id = #{rule}")
      .should eq [["Miete", "100000", anna.to_s, "4", "Warm", "equal"]]
    RY.rows(world, "SELECT DISTINCT participant_id, amount_cents FROM expense_shares WHERE expense_id IN (SELECT id FROM expenses WHERE recurring_id = #{rule}) ORDER BY 1")
      .should eq [[anna.to_s, "50000"], [ben.to_s, "50000"]]
    RY.rows(world, "SELECT action, coalesce(actor_id, 'system'), count(*) FROM activity WHERE expense_id IN (SELECT id FROM expenses WHERE recurring_id = #{rule} AND id != #{miete}) GROUP BY 1, 2")
      .should eq [["expense_created", "system", "8"]]
    RY.rows(world, "SELECT actor_id, expense_id, details_json FROM activity WHERE action = 'recurring_created'")
      .should eq [[anna.to_s, miete.to_s, %({"title":"Miete","amount_cents":100000,"text":"„Miete“ wiederholt sich jetzt monatlich."})]]

    # The expense (and each instance) already belongs to the rule.
    r = user.post(neu, {"ausgabe" => miete.to_s, "haeufigkeit" => "weekly"})
    r.status.should eq 422
    r.error_message.should eq "Diese Ausgabe gehört schon zu einer wiederkehrenden Ausgabe."
    instance = RY.value(world, "SELECT id FROM expenses WHERE recurring_id = #{rule} AND date = '2026-02-28'").to_i64
    ids["miete-feb"] = instance
    r = user.get("#{neu}?ausgabe=#{instance}")
    r.status.should eq 200
    r.text.should contain "Diese Ausgabe gehört schon zu einer wiederkehrenden Ausgabe."
    RY.attr(r, %(//a[normalize-space()="Zu den wiederkehrenden Ausgaben"]/@href)).should eq [list]
    r.doc.xpath_nodes(%(//input[@name="haeufigkeit"])).size.should eq 0
    r.error_message.should be_nil
    user.post(neu, {"ausgabe" => instance.to_s, "haeufigkeit" => "yearly"}).status.should eq 422
    E2E::Database.count(world.app.db_path, "SELECT count(*) FROM recurring").should eq 1
  end

  scenario "weekly rule, leap-day yearly rule, a rule without missed dates and long previews", world do
    user = world.user
    user.login("Anna")
    gemuese = ids["gemuese"] = RY.create(world, user, RY.form("Gemüsekiste", "2026-09-19", "28,90", ben, [anna, ben], category: 1))
    r = user.post(neu, {"ausgabe" => gemuese.to_s, "haeufigkeit" => "weekly"})
    r.flash.should eq "„Gemüsekiste“ wiederholt sich jetzt wöchentlich. 2 Ausgaben nachgetragen."
    rules["gemuese"] = rule_of.call(gemuese)
    dates_of.call(rules["gemuese"]).should eq %w(2026-09-19 2026-09-26 2026-10-03)
    rule_row.call(rules["gemuese"]).should eq ["weekly", "2026-09-19", "2026-10-10", "1"]

    haft = ids["haft"] = RY.create(world, user, RY.form("Haftpflicht", "2020-02-29", "89,40", anna, [anna, ben]))
    r = user.get("#{neu}?ausgabe=#{haft}")
    labels.call(r).should eq [
      "Wöchentlich – nächster Termin 07.03.2020; 344 verpasste Termine werden sofort eingetragen",
      "Monatlich – nächster Termin 29.03.2020; 79 verpasste Termine werden sofort eingetragen",
      "Jährlich – nächster Termin 28.02.2021; 6 verpasste Termine werden sofort eingetragen",
    ]
    r = user.post(neu, {"ausgabe" => haft.to_s, "haeufigkeit" => "yearly"})
    r.flash.should eq "„Haftpflicht“ wiederholt sich jetzt jährlich. 6 Ausgaben nachgetragen."
    rules["haft"] = rule_of.call(haft)
    dates_of.call(rules["haft"]).should eq %w(2020-02-29 2021-02-28 2022-02-28 2023-02-28 2024-02-29 2025-02-28 2026-02-28)
    rule_row.call(rules["haft"]).should eq ["yearly", "2020-02-29", "2027-02-28", "1"]

    blumen = ids["blumen"] = RY.create(world, user, RY.form("Blumen", "2026-10-03", "5,00", anna, [anna]))
    r = user.get("#{neu}?ausgabe=#{blumen}")
    labels.call(r).should eq [
      "Wöchentlich – nächster Termin 10.10.2026",
      "Monatlich – nächster Termin 03.11.2026",
      "Jährlich – nächster Termin 03.10.2027",
    ]
    r = user.post(neu, {"ausgabe" => blumen.to_s, "haeufigkeit" => "weekly"})
    r.status.should eq 303
    r.flash.should eq "„Blumen“ wiederholt sich jetzt wöchentlich."
    rules["blumen"] = rule_of.call(blumen)
    dates_of.call(rules["blumen"]).should eq %w(2026-10-03)
    rule_row.call(rules["blumen"]).should eq ["weekly", "2026-10-03", "2026-10-10", "1"]

    # Previews of very old expenses (no rule is created).
    alt = RY.create(world, user, RY.form("Altlast", "2015-01-03", "1,00", anna, [anna]))
    labels.call(user.get("#{neu}?ausgabe=#{alt}")).should eq [
      "Wöchentlich – nächster Termin 10.01.2015; 613 verpasste Termine werden eingetragen – die ersten 400 Termine sofort, der Rest in den nächsten Stunden",
      "Monatlich – nächster Termin 03.02.2015; 141 verpasste Termine werden sofort eingetragen",
      "Jährlich – nächster Termin 03.01.2016; 11 verpasste Termine werden sofort eingetragen",
    ]
    uralt = RY.create(world, user, RY.form("Uralt", "2000-01-01", "1,00", anna, [anna]))
    labels.call(user.get("#{neu}?ausgabe=#{uralt}")).should eq [
      "Wöchentlich – nächster Termin 08.01.2000; mehr als 1000 verpasste Termine werden eingetragen – die ersten 400 Termine sofort, der Rest in den nächsten Stunden",
      "Monatlich – nächster Termin 01.02.2000; 321 verpasste Termine werden sofort eingetragen",
      "Jährlich – nächster Termin 01.01.2001; 26 verpasste Termine werden sofort eingetragen",
    ]
    # A deleted expense cannot become a rule.
    user.post("/ausgaben/#{alt}/loeschen").status.should eq 303
    user.get("#{neu}?ausgabe=#{alt}").status.should eq 404
    user.post(neu, {"ausgabe" => alt.to_s, "haeufigkeit" => "weekly"}).status.should eq 404
  end

  scenario "occurrences equal to an existing expense are skipped", world do
    user = world.user
    user.login("Anna")
    zeitung = ids["zeitung"] = RY.create(world, user, RY.form("Zeitung", "2026-07-10", "24,90", anna, [anna, ben]))
    manual = ids["zeitung-manuell"] = RY.create(world, user, RY.form("Zeitung", "2026-09-10", "24,90", anna, [anna, ben]))
    # Not equal: other amount, other payer, deleted.
    RY.create(world, user, RY.form("Zeitung", "2026-08-10", "25,00", anna, [anna, ben]))
    RY.create(world, user, RY.form("Zeitung", "2026-08-10", "24,90", ben, [anna, ben]))
    gone = RY.create(world, user, RY.form("Zeitung", "2026-08-10", "24,90", anna, [anna]))
    user.post("/ausgaben/#{gone}/loeschen").status.should eq 303

    r = user.get("#{neu}?ausgabe=#{zeitung}")
    labels.call(r)[1].should eq "Monatlich – nächster Termin 10.08.2026; 1 verpasster Termin wird sofort eingetragen; 1 bereits als Ausgabe vorhandener Termin wird übersprungen"
    r = user.post(neu, {"ausgabe" => zeitung.to_s, "haeufigkeit" => "monthly"})
    r.flash.should eq "„Zeitung“ wiederholt sich jetzt monatlich. 1 Ausgabe nachgetragen."
    rules["zeitung"] = rule_of.call(zeitung)
    dates_of.call(rules["zeitung"]).should eq %w(2026-07-10 2026-08-10)
    rule_row.call(rules["zeitung"]).should eq ["monthly", "2026-07-10", "2026-10-10", "1"]
    RY.value(world, "SELECT coalesce(recurring_id, 'NULL') FROM expenses WHERE id = #{manual}").should eq "NULL"
    E2E::Database.count(world.app.db_path, "SELECT count(*) FROM expenses WHERE title = 'Zeitung' AND deleted_at IS NULL").should eq 5

    # A rule whose next occurrence is entered by hand in advance (see the
    # restart below).
    strom = ids["strom"] = RY.create(world, user, RY.form("Strom", "2026-08-31", "60,00", ben, [anna, ben]))
    r = user.post(neu, {"ausgabe" => strom.to_s, "haeufigkeit" => "monthly"})
    r.flash.should eq "„Strom“ wiederholt sich jetzt monatlich. 1 Ausgabe nachgetragen."
    rules["strom"] = rule_of.call(strom)
    dates_of.call(rules["strom"]).should eq %w(2026-08-31 2026-09-30)
    ids["strom-oktober"] = RY.create(world, user, RY.form("Strom", "2026-10-31", "60,00", ben, [anna, ben]))
  end

  scenario "pause, resume, take over the template, delete", world do
    user = world.user
    user.login("Anna")
    g = rules["gemuese"]
    r = user.post("#{list}/#{g}/pausieren")
    r.status.should eq 303
    r.location.should eq list
    r.flash.should eq "Pausiert."
    rule_row.call(g).should eq ["weekly", "2026-09-19", "2026-10-10", "0"]
    # Resuming before the next date keeps it and creates nothing.
    r = user.post("#{list}/#{g}/fortsetzen")
    r.flash.should eq "Fortgesetzt."
    rule_row.call(g).should eq ["weekly", "2026-09-19", "2026-10-10", "1"]
    user.post("#{list}/#{g}/pausieren").flash.should eq "Pausiert."

    # The rent goes up: edit the newest instance, then take it as template.
    sept = RY.value(world, "SELECT id FROM expenses WHERE recurring_id = #{rules["miete"]} AND date = '2026-09-30'").to_i64
    RY.update(user, sept, RY.form("Miete", "2026-09-30", "1100,00", anna, [anna, ben], category: 4, notes: "Warm"))
    r = user.post("#{list}/#{rules["miete"]}/vorlage")
    r.status.should eq 303
    r.location.should eq list
    r.flash.should eq "Vorlage aus der letzten Ausgabe übernommen."
    RY.value(world, "SELECT template_json FROM recurring WHERE id = #{rules["miete"]}").should contain %("amount_cents":110000)

    # Without any instance left the template stays.
    user.post("/ausgaben/#{ids["blumen"]}/loeschen").status.should eq 303
    r = user.post("#{list}/#{rules["blumen"]}/vorlage")
    r.status.should eq 303
    r.flash.should eq "Es gibt keine Ausgabe dieser Wiederholung mehr, aus der die Vorlage übernommen werden könnte."

    r = user.get(list)
    rows = r.doc.xpath_nodes("//tbody/tr").map do |tr|
      [tr.xpath_node(".//strong").not_nil!.content, tr.xpath_node(".//span[@class='muted']").not_nil!.content,
       tr.xpath_node("./td[2]").not_nil!.content.strip, tr.xpath_node("./td[3]").not_nil!.content.strip,
       tr.xpath_nodes(".//button").map(&.content.strip).join("|")]
    end
    actions = "Pausieren|Vorlage aktualisieren|Wiederholung löschen"
    rows.should eq [
      ["Blumen", "Wöchentlich seit 03.10.2026 · zahlt Anna", "5,00 €", "10.10.2026", actions],
      ["Zeitung", "Monatlich seit 10.07.2026 · zahlt Anna", "24,90 €", "10.10.2026", actions],
      ["Miete", "Monatlich seit 31.01.2026 · zahlt Anna", "1.100,00 €", "31.10.2026", actions],
      ["Strom", "Monatlich seit 31.08.2026 · zahlt Ben", "60,00 €", "31.10.2026", actions],
      ["Haftpflicht", "Jährlich seit 29.02.2020 · zahlt Anna", "89,40 €", "28.02.2027", actions],
      ["Gemüsekiste", "Wöchentlich seit 19.09.2026 · zahlt Ben", "28,90 €", "pausiert", "Fortsetzen|Vorlage aktualisieren|Wiederholung löschen"],
    ]
    RY.attr(r, %(//form[button[normalize-space()="Wiederholung löschen"]]/@action)).should contain "#{list}/#{rules["zeitung"]}/loeschen"

    # Deleting the rule keeps its expenses.
    zeitung_ids = RY.column(world, "SELECT id FROM expenses WHERE recurring_id = #{rules["zeitung"]} ORDER BY id")
    r = user.post("#{list}/#{rules["zeitung"]}/loeschen")
    r.status.should eq 303
    r.flash.should eq "Wiederholung gelöscht. Bereits angelegte Ausgaben bleiben erhalten."
    E2E::Database.count(world.app.db_path, "SELECT count(*) FROM recurring WHERE id = #{rules["zeitung"]}").should eq 0
    RY.rows(world, "SELECT id, coalesce(recurring_id, 'NULL'), coalesce(deleted_at, 'NULL') FROM expenses WHERE id IN (#{zeitung_ids.join(",")}) ORDER BY id")
      .should eq zeitung_ids.map { |i| [i, "NULL", "NULL"] }
    RY.rows(world, "SELECT actor_id, coalesce(expense_id, 'NULL'), details_json FROM activity WHERE action = 'recurring_deleted'")
      .should eq [[anna.to_s, "NULL", %({"title":"Zeitung","amount_cents":2490,"text":"Wiederholung von „Zeitung“ beendet."})]]
    %w(pausieren fortsetzen vorlage loeschen).each do |action|
      user.post("#{list}/#{rules["zeitung"]}/#{action}").status.should eq 404
    end

    texts = RY.activity(user)
    texts.should contain "Anna: Wiederholung „Gemüsekiste“ (wöchentlich) pausiert"
    texts.should contain "Anna: Wiederholung „Gemüsekiste“ (wöchentlich) fortgesetzt"
    texts.should contain "Anna: Wiederholung „Miete“ (monatlich): Vorlage aus der letzten Ausgabe übernommen"
    texts.should contain "Anna: Wiederholung von „Zeitung“ beendet."
    texts.should contain "Anna: „Miete“ wiederholt sich jetzt monatlich."
    texts.should contain "Automatisch hat „Gemüsekiste“ angelegt (28,90 €)."
  end

  scenario "expense pages show the recurring badge and links", world do
    user = world.user
    user.login("Anna")
    feb = ids["miete-feb"]
    r = user.get("/ausgaben/#{feb}")
    r.status.should eq 200
    RY.texts(r, %(//a[contains(@class, "badge")][@href="#{list}"])).should eq ["Wiederkehrend"]
    r.text.should contain "Diese Ausgabe wird automatisch wiederholt. Wiederkehrende Ausgaben verwalten"
    RY.attr(r, %(//a[normalize-space()="Wiederkehrende Ausgaben verwalten"]/@href)).should eq [list]
    r.doc.xpath_nodes(%(//a[starts-with(@href, "#{neu}")])).size.should eq 0
    RY.texts(r, %(//*[contains(@class, "activity-main")]/div[1])).should eq ["Automatisch hat „Miete“ angelegt (1.000,00 €)."]

    # The expenses of the deleted rule are plain expenses again.
    zeitung = ids["zeitung"]
    r = user.get("/ausgaben/#{zeitung}")
    r.doc.xpath_nodes(%(//a[contains(@class, "badge")][@href="#{list}"])).size.should eq 0
    RY.texts(r, %(//a[@href="#{neu}?ausgabe=#{zeitung}"])).should eq ["Als wiederkehrend einrichten"]

    home = user.get("/")
    gem = RY.value(world, "SELECT id FROM expenses WHERE recurring_id = #{rules["gemuese"]} AND date = '2026-10-03'")
    home.doc.xpath_nodes(%(//a[@id="ausgabe-#{gem}"]//span[@title="Wiederkehrend"])).size.should eq 1
    home.doc.xpath_nodes(%(//a[@id="ausgabe-#{ids["zeitung-manuell"]}"]//span[@title="Wiederkehrend"])).size.should eq 0
    home.doc.xpath_nodes(%(//a[@id="ausgabe-#{ids["strom-oktober"]}"]//span[@title="Wiederkehrend"])).size.should eq 0
  end

  scenario "after a restart the job enters due occurrences; resuming does not catch up", world do
    # Saturday, 31 October 2026.
    world.restart("2026-10-31T10:00:00Z")
    RY.wait_count(world, "SELECT count(*) FROM expenses WHERE recurring_id = #{rules["miete"]} AND date = '2026-10-31'", 1)
    RY.wait_count(world, "SELECT count(*) FROM expenses WHERE recurring_id = #{rules["blumen"]}", 5)
    user = world.user
    user.login("Anna")

    RY.rows(world, "SELECT amount_cents, created_at FROM expenses WHERE recurring_id = #{rules["miete"]} AND date = '2026-10-31'")
      .should eq [["110000", "2026-10-31T10:00:00Z"]]
    rule_row.call(rules["miete"]).should eq ["monthly", "2026-01-31", "2026-11-30", "1"]
    # The deleted template expense does not stop the weekly flowers.
    dates_of.call(rules["blumen"]).should eq %w(2026-10-10 2026-10-17 2026-10-24 2026-10-31)
    rule_row.call(rules["blumen"]).should eq ["weekly", "2026-10-03", "2026-11-07", "1"]
    # The electricity bill entered by hand is not doubled.
    dates_of.call(rules["strom"]).should eq %w(2026-08-31 2026-09-30)
    rule_row.call(rules["strom"]).should eq ["monthly", "2026-08-31", "2026-11-30", "1"]
    E2E::Database.count(world.app.db_path, "SELECT count(*) FROM expenses WHERE title = 'Strom' AND deleted_at IS NULL").should eq 3
    # Paused: nothing happened.
    dates_of.call(rules["gemuese"]).should eq %w(2026-09-19 2026-09-26 2026-10-03)
    rule_row.call(rules["haft"]).should eq ["yearly", "2020-02-29", "2027-02-28", "1"]

    r = user.post("#{list}/#{rules["gemuese"]}/fortsetzen")
    r.status.should eq 303
    r.flash.should eq "Fortgesetzt. 1 Ausgabe angelegt."
    dates_of.call(rules["gemuese"]).should eq %w(2026-09-19 2026-09-26 2026-10-03 2026-10-31)
    rule_row.call(rules["gemuese"]).should eq ["weekly", "2026-09-19", "2026-11-07", "1"]

    texts = RY.activity(user)
    texts.first(7).sort.should eq [
      "Anna: Wiederholung „Gemüsekiste“ (wöchentlich) fortgesetzt",
      "Automatisch hat „Blumen“ angelegt (5,00 €).",
      "Automatisch hat „Blumen“ angelegt (5,00 €).",
      "Automatisch hat „Blumen“ angelegt (5,00 €).",
      "Automatisch hat „Blumen“ angelegt (5,00 €).",
      "Automatisch hat „Gemüsekiste“ angelegt (28,90 €).",
      "Automatisch hat „Miete“ angelegt (1.100,00 €).",
    ]

    blumen = RY.column(world, "SELECT id FROM expenses WHERE recurring_id = #{rules["blumen"]} ORDER BY id")
    user.post("#{list}/#{rules["blumen"]}/loeschen").status.should eq 303
    E2E::Database.count(world.app.db_path, "SELECT count(*) FROM expenses WHERE id IN (#{blumen.join(",")}) AND deleted_at IS NULL AND recurring_id IS NULL").should eq 4
    r = user.get(list)
    RY.texts(r, "//tbody/tr//strong").should eq ["Gemüsekiste", "Miete", "Strom", "Haftpflicht"]
  end
end

# The YNAB sync (/einstellungen/ynab): connection, plan/account/start date,
# category mapping and what ends up in YNAB (the fake keeps all
# transactions). Each sync runs 300 ms after a change.
describe "YNAB sync" do
  world = E2E::World.new("ynab")
  after_all { world.stop }

  page = "/einstellungen/ynab"
  token = FakeYNAB::TOKEN
  target = "#{FakeYNAB::PLAN}|#{FakeYNAB::ACCOUNT}"
  post_txns = "POST /v1/plans/plan-1/transactions"
  patch_txns = "PATCH /v1/plans/plan-1/transactions"
  get_plans = "GET /v1/plans"
  ids = {} of String => Int64
  anna = ben = 0_i64

  marker = ->(id : Int64) { "zipfelkasse ##{id}" }
  h2 = ->(r : E2E::Response) { RY.texts(r, "//h2") }
  alerts = ->(r : E2E::Response) { RY.texts(r, %(//*[@role="alert"])) }
  status_texts = ->(r : E2E::Response) { RY.texts(r, %(//section[.//h2[.="Status"]]//p)) }
  sync_rows = -> { RY.rows(world, "SELECT expense_id, ynab_txn_id, synced_hash, last_error FROM ynab_sync ORDER BY expense_id") }
  config = ->(cols : String) { RY.rows(world, "SELECT #{cols} FROM ynab_config").first? }
  fail = ->(status : Int32) { world.app.ynab.fail(status) }

  scenario "settings page without a connection, token validation and connecting", world do
    user = world.user
    user.login("Anna").status.should eq 303
    user.post("/einstellungen/teilnehmer", {"name" => "Ben"}).status.should eq 303
    anna = RY.person(world, "Anna")
    ben = RY.person(world, "Ben")
    # Entered before connecting (all at the frozen 12:00).
    ids["einkauf"] = RY.create(world, user, RY.form("Wocheneinkauf", "2026-09-20", "42,00", anna, [anna, ben], category: 1))
    ids["kino"] = RY.create(world, user, RY.form("Kino", "2026-08-15", "30,00", anna, [anna, ben], category: 7))
    ids["rueck"] = RY.create(world, user, RY.form("Rückzahlung", "2026-09-25", "20,00", ben, [anna], reimbursement: true))
    ids["bens"] = RY.create(world, user, RY.form("Bens Sache", "2026-09-22", "15,00", ben, [ben]))
    ids["konzert"] = RY.create(world, user, RY.form("Konzert", "2026-10-10", "80,00", anna, [anna, ben]))
    ids["pizza"] = RY.create(world, user, RY.form("Pizza", "2026-09-28", "36,00", ben, [anna, ben], category: 2))

    calls = RY.ynab_calls(world) do
      r = user.get(page)
      r.status.should eq 200
      RY.h1(r).should eq "YNAB"
      h2.call(r).should eq ["Verbindung"]
      RY.texts(r, %(//label[@for="token"])).should eq ["Token"]
      RY.texts(r, %(//form[@action="#{page}/token"]//button)).should eq ["Verbinden"]
      r.doc.xpath_nodes(%(//form[@action="#{page}/trennen"])).size.should eq 0
      r.text.should_not contain "Token: gesetzt"

      # Checked before asking YNAB.
      {"", "   "}.each do |t|
        r = user.post("#{page}/token", {"token" => t})
        r.status.should eq 422
        r.error_message.should eq "Bitte einen Token eingeben."
      end
      ["ab cd", "ab\tcd", "x" * 201].each do |t|
        r = user.post("#{page}/token", {"token" => t})
        r.status.should eq 422
        r.error_message.should eq "Das sieht nicht wie ein YNAB-Token aus."
      end
    end
    calls.should(be_empty)

    calls = RY.ynab_calls(world, 1) do
      r = user.post("#{page}/token", {"token" => "wrong"})
      r.status.should eq 422
      r.error_message.should eq "YNAB kennt diesen Token nicht. Bitte prüfen und neu kopieren."
    end
    calls.should(eq [get_plans])
    E2E::Database.count(world.app.db_path, "SELECT count(*) FROM ynab_config").should eq 0

    fail.call(503)
    r = user.post("#{page}/token", {"token" => "  #{token}  "})
    r.status.should eq 422
    r.error_message.should eq "YNAB ist gerade nicht erreichbar: YNAB-Fehler 503: Error 503 with •••"
    r.body.should_not contain token
    E2E::Database.count(world.app.db_path, "SELECT count(*) FROM ynab_config").should eq 0

    r = user.post("#{page}/token", {"token" => "  #{token}  "})
    r.status.should eq 303
    r.location.should eq page
    r.flash.should eq "Token gespeichert."
    config.call("token, budget_id, account_id, coalesce(start_date, 'NULL'), enabled, token_invalid").should eq [token, "", "", "NULL", "1", "0"]

    calls = RY.ynab_calls(world) do
      r = user.get(page)
      r.status.should eq 200
      r.body.should_not contain token
      h2.call(r).should eq ["Verbindung", "Plan und Konto", "Status"]
      r.text.should contain "Token: gesetzt"
      RY.texts(r, %(//label[@for="token"])).should eq ["Token ersetzen"]
      RY.texts(r, %(//form[@action="#{page}/token"]//button)).should eq ["Token ersetzen"]
      RY.texts(r, %(//form[@action="#{page}/trennen"]//button)).should eq ["Verbindung trennen"]
      RY.options(r, "ziel").should eq [["", "Bitte wählen …"], ["plan-1|acc-geteilt", "Geteilt"], ["plan-1|acc-giro", "Girokonto"]]
      RY.attr(r, "//select[@id='ziel']/optgroup/@label").should eq ["Haushalt"]
      RY.selected(r, "ziel").should be_empty
      RY.attr(r, "//input[@id='start']/@value").should eq ["2026-10-03"]
      status_texts.call(r).should eq [
        "Dein Saldo in Zipfelkasse: 38,00 € – so viel sollte auch „Geteilt“ in YNAB zeigen.",
        "Sobald Plan, Konto und Startdatum gewählt sind, synchronisiert Zipfelkasse automatisch: kurz nach jeder Änderung und stündlich.",
      ]
      r.doc.xpath_nodes(%(//form[@action="#{page}/sync"])).size.should eq 0
      r.doc.xpath_nodes(%(//form[@action="#{page}/kategorien"])).size.should eq 0

      r = user.post("#{page}/sync")
      r.status.should eq 422
      r.error_message.should eq "YNAB ist noch nicht fertig eingerichtet (Token, Plan, Konto und Startdatum)."
      r = user.post("#{page}/kategorien", {"kat-1" => "c-food"})
      r.status.should eq 422
      r.error_message.should eq "Bitte zuerst Token, Plan und Konto einrichten."
      ["plan-1|acc-depot", "plan-1|acc-alt", "plan-2|acc-geteilt", "plan-1", "", "plan-1|"].each do |ziel|
        r = user.post("#{page}/konto", {"ziel" => ziel, "start" => "2026-09-01"})
        r.status.should eq 422
        r.error_message.should eq "Bitte Plan und Konto auswählen."
      end
      ["", "broken", "31.02.2026", "1999-12-31", "2026-13-01"].each do |start|
        r = user.post("#{page}/konto", {"ziel" => target, "start" => start})
        r.status.should eq 422
        r.error_message.should eq "Bitte ein gültiges Startdatum angeben."
      end
    end
    calls.should(be_empty)
    config.call("budget_id, account_id, coalesce(start_date, 'NULL')").should eq ["", "", "NULL"]
    RY.activity(user).first.should eq "Anna: YNAB verbunden (Token gesetzt)"
  end

  scenario "choosing plan and account syncs the selected expenses", world do
    # Five minutes later: everything above was entered before connecting.
    world.restart("2026-10-03T10:05:00Z")
    user = world.user
    user.login("Anna")
    calls = RY.ynab_calls(world, 2) do
      r = user.post("#{page}/konto", {"ziel" => target, "start" => "01.09.2026"})
      r.status.should eq 303
      r.location.should eq page
      r.flash.should eq "Gespeichert."
    end
    calls.should(eq [get_plans, post_txns])
    config.call("budget_id, account_id, start_date, connected_at, summary, error")
      .should eq ["plan-1", "acc-geteilt", "2026-09-01", "2026-10-03T10:05:00Z", "2 neu · 0 geändert · 0 gelöscht", ""]
    # Not sent: before the start date, reimbursement, no share, in the future.
    RY.live(world).should eq [
      ["2026-09-20", -21000, "Wocheneinkauf", "Gesamt 42,00 € · bezahlt von Anna · #{marker.call(ids["einkauf"])}", nil, "cleared", true, "acc-geteilt"],
      ["2026-09-28", -18000, "Pizza", "Gesamt 36,00 € · bezahlt von Ben · #{marker.call(ids["pizza"])}", nil, "cleared", true, "acc-geteilt"],
    ]
    sync_rows.call.map(&.first(2)).should eq [[ids["einkauf"].to_s, "t1"], [ids["pizza"].to_s, "t2"]]

    r = user.get(page)
    r.body.should_not contain token
    h2.call(r).should eq ["Verbindung", "Plan und Konto", "Kategorien", "Status"]
    RY.selected(r, "ziel").should eq [target]
    RY.attr(r, "//input[@id='start']/@value").should eq ["2026-09-01"]
    status_texts.call(r).should eq [
      "Dein Saldo in Zipfelkasse: 38,00 € – so viel sollte auch „Geteilt“ in YNAB zeigen.",
      "Synchronisierte Buchungen: 2",
      "Letzter Abgleich: 03.10.2026, 12:05 (2 neu · 0 geändert · 0 gelöscht)",
    ]
    RY.texts(r, %(//form[@action="#{page}/sync"]//button)).should eq ["Jetzt synchronisieren"]
    # Every active category; YNAB categories without internal, credit card
    # and hidden ones.
    RY.texts(r, "//section[.//h2[.='Kategorien']]//tbody//label").should eq [
      "Lebensmittel", "Restaurant", "Haushalt", "Miete & Nebenkosten", "Transport", "Reisen", "Freizeit",
      "Gesundheit", "Geschenke", "Sonstiges",
    ]
    RY.options(r, "kat-1").should eq [
      ["", "– unkategorisiert –"], ["c-food", "Lebensmittel & Drogerie"], ["c-out", "Essen gehen"],
      ["c-rent", "Miete"], ["c-fun", %(Kino & "Konzerte")],
    ]
    RY.attr(r, "//select[@id='kat-1']/optgroup/@label").should eq ["Alltag", "Wohnen & <Freizeit>"]
    RY.selected(r, "kat-1").should be_empty
    RY.activity(user).first.should eq "Anna: YNAB: Konto „Geteilt“ im Plan „Haushalt“ gewählt, Startdatum 01.09.2026"
  end

  scenario "category mapping", world do
    user = world.user
    user.login("Anna")
    calls = RY.ynab_calls(world) do
      {"c-unknown", "c-old", "c-rta", "c-visa"}.each do |cat|
        r = user.post("#{page}/kategorien", {"kat-1" => cat})
        r.status.should eq 422
        r.error_message.should eq "Unbekannte YNAB-Kategorie. Bitte die Seite neu laden."
      end
      r = user.post("#{page}/kategorien", {"kat-999" => "c-food"})
      r.status.should eq 422
      r.error_message.should eq "Unbekannte Kategorie."
    end
    calls.should(be_empty)
    E2E::Database.count(world.app.db_path, "SELECT count(*) FROM ynab_category_map").should eq 0

    calls = RY.ynab_calls(world, 1) do
      r = user.post("#{page}/kategorien", {"kat-1" => "c-food", "kat-2" => "c-out", "kat-3" => "", "kat-x" => "c-rent", "andere" => "c-rent"})
      r.status.should eq 303
      r.location.should eq page
      r.flash.should eq "Kategorie-Zuordnung gespeichert."
    end
    calls.should(eq [patch_txns])
    RY.rows(world, "SELECT category_id, ynab_category_id FROM ynab_category_map ORDER BY 1").should eq [["1", "c-food"], ["2", "c-out"]]
    RY.live(world).map { |t| [t[2], t[4], t[1]] }.should eq [["Wocheneinkauf", "c-food", -21000], ["Pizza", "c-out", -18000]]
    config.call("summary").should eq ["0 neu · 2 geändert · 0 gelöscht"]
    r = user.get(page)
    RY.selected(r, "kat-1").should eq ["c-food"]
    RY.selected(r, "kat-2").should eq ["c-out"]
    RY.selected(r, "kat-3").should be_empty
    RY.activity(user).first.should eq "Anna: YNAB: Kategorie-Zuordnung geändert (Lebensmittel → Lebensmittel & Drogerie, Restaurant → Essen gehen)"
  end

  scenario "changes after connecting are synced: backdated, future, edit, share 0, delete, start date", world do
    user = world.user
    user.login("Anna")
    # Entered after connecting: synced although dated before the start.
    calls = RY.ynab_calls(world, 1) do
      ids["nachtrag"] = RY.create(world, user, RY.form("Nachtrag", "2026-08-01", "10,00", anna, [anna, ben], category: 1))
    end
    calls.should(eq [post_txns])
    RY.live(world).last.should eq ["2026-08-01", -5000, "Nachtrag", "Gesamt 10,00 € · bezahlt von Anna · #{marker.call(ids["nachtrag"])}", "c-food", "cleared", true, "acc-geteilt"]

    calls = RY.ynab_calls(world) do
      ids["zukunft"] = RY.create(world, user, RY.form("Zukunft", "2026-10-04", "10,00", anna, [anna, ben]))
      ids["ohne"] = RY.create(world, user, RY.form("Ohne Anna", "2026-10-01", "10,00", ben, [ben]))
    end
    calls.should(be_empty)

    calls = RY.ynab_calls(world, 1) do
      RY.update(user, ids["einkauf"], RY.form("Wocheneinkauf", "2026-09-20", "50,00", anna, [anna, ben], category: 1))
    end
    calls.should(eq [patch_txns])
    RY.live(world).first.should eq ["2026-09-20", -25000, "Wocheneinkauf", "Gesamt 50,00 € · bezahlt von Anna · #{marker.call(ids["einkauf"])}", "c-food", "cleared", true, "acc-geteilt"]

    # Anna no longer takes part: the transaction is deleted.
    calls = RY.ynab_calls(world, 1) do
      RY.update(user, ids["pizza"], RY.form("Pizza", "2026-09-28", "36,00", ben, [ben], category: 2))
    end
    calls.should(eq ["DELETE /v1/plans/plan-1/transactions/t2"])
    calls = RY.ynab_calls(world, 1) do
      user.post("/ausgaben/#{ids["nachtrag"]}/loeschen").status.should eq 303
    end
    calls.should(eq ["DELETE /v1/plans/plan-1/transactions/t3"])
    RY.txn_ids(world).should eq [{"t1", false}, {"t2", true}, {"t3", true}]
    sync_rows.call.map(&.first(2)).should eq [[ids["einkauf"].to_s, "t1"]]

    # An earlier start date adds, a later one keeps what is in YNAB.
    calls = RY.ynab_calls(world, 1) do
      user.post("#{page}/konto", {"ziel" => target, "start" => "2026-08-01"}).status.should eq 303
    end
    calls.should(eq [post_txns])
    RY.live(world).map { |t| [t[2], t[0], t[1], t[4]] }.should eq [["Wocheneinkauf", "2026-09-20", -25000, "c-food"], ["Kino", "2026-08-15", -15000, nil]]
    calls = RY.ynab_calls(world) do
      user.post("#{page}/konto", {"ziel" => target, "start" => "2026-09-25"}).status.should eq 303
    end
    calls.should(be_empty)
    RY.live(world).size.should eq 2
    config.call("start_date, connected_at").should eq ["2026-09-25", "2026-10-03T10:05:00Z"]
    activity = RY.activity(user)
    activity[0].should eq "Anna: YNAB: Startdatum 01.08.2026 → 25.09.2026"
    activity[1].should eq "Anna: YNAB: Startdatum 01.09.2026 → 01.08.2026"

    # "Jetzt synchronisieren" finds nothing to do.
    calls = RY.ynab_calls(world) do
      r = user.post("#{page}/sync")
      r.status.should eq 303
      r.location.should eq page
      r.flash.should eq "Synchronisierung gestartet – Status unten aktualisiert sich nach dem Neuladen."
    end
    calls.should(be_empty)
    r = user.get(page)
    status_texts.call(r)[1..].should eq [
      "Synchronisierte Buchungen: 2",
      "Letzter Abgleich: 03.10.2026, 12:05 (0 neu · 0 geändert · 0 gelöscht)",
    ]
  end

  scenario "rate limit, outages and rejected transactions", world do
    user = world.user
    user.login("Anna")
    fail.call(429)
    calls = RY.ynab_calls(world, 1) do
      ids["baecker"] = RY.create(world, user, RY.form("Bäcker", "2026-10-02", "8,00", anna, [anna, ben]))
    end
    calls.should(eq [post_txns])
    RY.live(world).size.should eq 2
    config.call("retry_at, backoff_seconds, error").should eq [
      "2026-10-03T10:10:00Z", "300", "Das YNAB-Anfragelimit ist erreicht. Nächster Versuch um 12:10 Uhr.",
    ]
    r = user.get(page)
    alerts.call(r).should eq ["Das YNAB-Anfragelimit ist erreicht. Nächster Versuch um 12:10 Uhr."]
    status_texts.call(r).last.should eq "Nächster Versuch ab 03.10.2026, 12:10."
    # Paused: neither changes nor the button reach YNAB.
    calls = RY.ynab_calls(world) do
      user.post("#{page}/sync").status.should eq 303
    end
    calls.should(be_empty)

    # After the pause the next run (here the one at startup) catches up.
    calls = RY.ynab_calls(world, 1) { world.restart("2026-10-03T10:11:00Z") }
    calls.should(eq [post_txns])
    RY.live(world).last[2].should eq "Bäcker"
    config.call("coalesce(retry_at, 'NULL'), backoff_seconds, error, summary").should eq ["NULL", "0", "", "1 neu · 0 geändert · 0 gelöscht"]

    # A server error leaves the transaction "pending"; the next run looks
    # for it before creating it again.
    user = world.user
    user.login("Anna")
    fail.call(500)
    calls = RY.ynab_calls(world, 1) do
      ids["getraenke"] = RY.create(world, user, RY.form("Getränke", "2026-10-03", "12,00", anna, [anna, ben]))
    end
    calls.should(eq [post_txns])
    RY.rows(world, "SELECT ynab_txn_id, synced_hash FROM ynab_sync WHERE expense_id = #{ids["getraenke"]}").should eq [["", "pending"]]
    config.call("retry_at, error").should eq ["2026-10-03T10:16:00Z", "YNAB-Fehler 500: Error 500 with •••"]
    r = user.get(page)
    r.body.should_not contain token
    alerts.call(r).should eq ["YNAB-Fehler 500: Error 500 with •••"]
    status_texts.call(r).last.should eq "Nächster Versuch ab 03.10.2026, 12:16."
    calls = RY.ynab_calls(world, 2) { world.restart("2026-10-03T10:17:00Z") }
    calls.should(eq ["GET /v1/plans/plan-1/accounts/acc-geteilt/transactions", post_txns])
    RY.live(world).map(&.[2]).should eq ["Wocheneinkauf", "Kino", "Bäcker", "Getränke"]

    # YNAB unreachable while choosing the account or loading the page.
    user = world.user
    user.login("Anna")
    fail.call(503)
    r = user.get(page)
    r.status.should eq 200
    alerts.call(r).should eq ["YNAB ist gerade nicht erreichbar: YNAB-Fehler 503: Error 503 with •••"]
    r.body.should_not contain token
    r.doc.xpath_nodes("//select[@id='ziel']").size.should eq 0
    r.text.should contain "Die Kategorien aus YNAB konnten nicht geladen werden."
    fail.call(503) # errors are not cached
    r = user.post("#{page}/konto", {"ziel" => target, "start" => "2026-09-01"})
    r.status.should eq 502
    r.error_message.should eq "YNAB ist gerade nicht erreichbar: YNAB-Fehler 503: Error 503 with •••"
    config.call("start_date").should eq ["2026-09-25"]
    r = user.get(page)
    alerts.call(r).should be_empty
    RY.selected(r, "ziel").should eq [target]

    # A transaction YNAB rejects is listed and only retried when it changes
    # or in a full sync.
    calls = RY.ynab_calls(world, 2) do
      ids["reject"] = RY.create(world, user, RY.form("Please REJECT", "2026-10-01", "6,00", anna, [anna, ben]))
    end
    calls.should(eq [post_txns, post_txns])
    RY.rows(world, "SELECT ynab_txn_id, substr(synced_hash, 1, 6), last_error FROM ynab_sync WHERE expense_id = #{ids["reject"]}")
      .should eq [["", "error:", "YNAB-Fehler 400: payee rejected"]]
    r = user.get(page)
    alerts.call(r).should be_empty
    status_texts.call(r)[1..].should eq [
      "Synchronisierte Buchungen: 4",
      "Letzter Abgleich: 03.10.2026, 12:17 (0 neu · 0 geändert · 0 gelöscht · 1 fehlgeschlagen)",
    ]
    RY.texts(r, "//section[.//h2[.='Status']]//h3").should eq ["Fehler bei einzelnen Ausgaben"]
    problems = r.doc.xpath_nodes("//section[.//h3]//tbody/tr").map { |tr| tr.xpath_nodes("td").map(&.content.strip) }
    problems.should eq [["01.10.2026", "Please REJECT", "YNAB-Fehler 400: payee rejected"]]
    RY.attr(r, "//section[.//h3]//tbody//a/@href").should eq ["/ausgaben/#{ids["reject"]}"]

    calls = RY.ynab_calls(world, 1) do
      ids["broetchen"] = RY.create(world, user, RY.form("Brötchen", "2026-10-03", "3,00", anna, [anna, ben]))
    end
    calls.should(eq [post_txns])
    RY.live(world).last[2].should eq "Brötchen"
    calls = RY.ynab_calls(world, 2) { user.post("#{page}/sync").status.should eq 303 }
    calls.should(eq [post_txns, post_txns])
    config.call("summary").should eq ["0 neu · 0 geändert · 0 gelöscht · 1 fehlgeschlagen"]

    calls = RY.ynab_calls(world, 1) do
      RY.update(user, ids["reject"], RY.form("Please accept", "2026-10-01", "6,00", anna, [anna, ben]))
    end
    calls.should(eq [post_txns])
    RY.live(world).last[2..3].should eq ["Please accept", "Gesamt 6,00 € · bezahlt von Anna · #{marker.call(ids["reject"])}"]
    r = user.get(page)
    r.doc.xpath_nodes("//h3").size.should eq 0
    status_texts.call(r)[1].should eq "Synchronisierte Buchungen: 6"
  end

  scenario "token of another YNAB user, invalid token, switching back without duplicates, disconnecting", world do
    user = world.user
    user.login("Anna")
    before = RY.live(world)
    calls = RY.ynab_calls(world, 1) do
      r = user.post("#{page}/token", {"token" => FakeYNAB::OTHER_TOKEN})
      r.status.should eq 303
      r.flash.should eq "Token gespeichert. Der bisher gewählte Plan ist mit diesem Token nicht erreichbar – bitte Plan und Konto neu wählen."
    end
    calls.should(eq [get_plans])
    config.call("budget_id, account_id, start_date").should eq ["", "", "2026-09-25"]
    RY.rows(world, "SELECT DISTINCT ynab_txn_id, synced_hash FROM ynab_sync").should eq [["", "retarget"]]
    r = user.get(page)
    h2.call(r).should eq ["Verbindung", "Plan und Konto", "Status"]
    RY.options(r, "ziel").should eq [["", "Bitte wählen …"], ["plan-2|acc-2", "Geteilt"]]
    RY.attr(r, "//select[@id='ziel']/optgroup/@label").should eq ["Anderer Haushalt"]
    r.doc.xpath_nodes(%(//form[@action="#{page}/sync"])).size.should eq 0
    RY.activity(user).first.should eq "Anna: YNAB-Token ersetzt (Plan und Konto zurückgesetzt)"

    calls = RY.ynab_calls(world, 1) do
      user.post("#{page}/token", {"token" => token}).flash.should eq "Token gespeichert."
    end
    calls.should(eq [get_plans])
    RY.activity(user).first.should eq "Anna: YNAB-Token ersetzt"

    # Back in the old account the transactions are found by their marker.
    calls = RY.ynab_calls(world, 2) do
      user.post("#{page}/konto", {"ziel" => target, "start" => "2026-08-01"}).status.should eq 303
    end
    calls.should(eq ["GET /v1/plans/plan-1/accounts/acc-geteilt/transactions", patch_txns])
    RY.live(world).should eq before
    config.call("summary, connected_at").should eq ["0 neu · 6 geändert · 0 gelöscht", "2026-10-03T10:17:00Z"]
    RY.activity(user).first.should eq "Anna: YNAB: Konto „Geteilt“ im Plan „Haushalt“ gewählt, Startdatum 01.08.2026"

    # The token expires: shown on the page, no more requests.
    fail.call(401)
    calls = RY.ynab_calls(world, 1) do
      RY.update(user, ids["baecker"], RY.form("Bäcker", "2026-10-02", "9,00", anna, [anna, ben]))
    end
    calls.should(eq [patch_txns])
    config.call("token_invalid, error").should eq ["1", "Der YNAB-Token ist ungültig oder abgelaufen. Bitte einen neuen Token eintragen."]
    r = user.get(page)
    h2.call(r).should eq ["Verbindung", "Kategorien", "Status"]
    alerts.call(r).should eq [
      "Der gespeicherte Token ist ungültig oder abgelaufen. Bitte einen neuen eintragen.",
      "Der YNAB-Token ist ungültig oder abgelaufen. Bitte einen neuen Token eintragen.",
    ]
    calls = RY.ynab_calls(world) do
      ids["eis"] = RY.create(world, user, RY.form("Eis", "2026-10-03", "4,00", anna, [anna, ben]))
      user.post("#{page}/sync").status.should eq 303
    end
    calls.should(be_empty)
    calls = RY.ynab_calls(world, 3) do
      user.post("#{page}/token", {"token" => token}).flash.should eq "Token gespeichert."
    end
    calls.should(eq [get_plans, post_txns, patch_txns])
    config.call("token_invalid, error, summary").should eq ["0", "", "1 neu · 1 geändert · 0 gelöscht"]
    RY.live(world).map { |t| [t[2], t[1]] }.should eq [
      ["Wocheneinkauf", -25000], ["Kino", -15000], ["Bäcker", -4500], ["Getränke", -6000], ["Brötchen", -1500],
      ["Please accept", -3000], ["Eis", -2000],
    ]

    # Disconnecting keeps everything in YNAB and stops the sync.
    live = RY.live(world)
    calls = RY.ynab_calls(world) do
      r = user.post("#{page}/trennen")
      r.status.should eq 303
      r.location.should eq page
      r.flash.should eq "YNAB-Verbindung getrennt. Die Buchungen in YNAB bleiben erhalten."
      RY.create(world, user, RY.form("Nach der Trennung", "2026-10-03", "10,00", anna, [anna, ben]))
      user.post("#{page}/sync").status.should eq 422
    end
    calls.should(be_empty)
    RY.live(world).should eq live
    config.call("token, enabled, budget_id, account_id").should eq ["", "0", "plan-1", "acc-geteilt"]
    r = user.get(page)
    RY.texts(r, %(//form[@action="#{page}/token"]//button)).should eq ["Verbinden"]
    r.doc.xpath_nodes(%(//form[@action="#{page}/trennen"])).size.should eq 0
    r.text.should_not contain "Token: gesetzt"
    # Plan and account are kept for reconnecting (so the category card stays).
    h2.call(r).should eq ["Verbindung", "Kategorien"]
    r.text.should contain "Die Kategorien aus YNAB konnten nicht geladen werden."
    RY.activity(user)[1].should eq "Anna: YNAB-Verbindung getrennt"
  end

  scenario "reconnecting, and expenses entered by the recurring job are synced too", world do
    user = world.user
    user.login("Anna")
    nach = RY.value(world, "SELECT id FROM expenses WHERE title = 'Nach der Trennung'").to_i64
    calls = RY.ynab_calls(world, 2) do
      user.post("#{page}/token", {"token" => token}).flash.should eq "Token gespeichert."
    end
    calls.should(eq [get_plans, post_txns])
    RY.live(world).last.should eq ["2026-10-03", -5000, "Nach der Trennung", "Gesamt 10,00 € · bezahlt von Anna · #{marker.call(nach)}", nil, "cleared", true, "acc-geteilt"]

    calls = RY.ynab_calls(world, 1) do
      r = user.post("/einstellungen/wiederkehrend/neu", {"ausgabe" => ids["einkauf"].to_s, "haeufigkeit" => "weekly"})
      r.flash.should eq "„Wocheneinkauf“ wiederholt sich jetzt wöchentlich. 1 Ausgabe nachgetragen."
    end
    calls.should(eq [post_txns])
    rule = RY.value(world, "SELECT recurring_id FROM expenses WHERE id = #{ids["einkauf"]}")
    sept = RY.value(world, "SELECT id FROM expenses WHERE recurring_id = #{rule} AND date = '2026-09-27'").to_i64
    RY.live(world).last.should eq ["2026-09-27", -25000, "Wocheneinkauf", "Gesamt 50,00 € · bezahlt von Anna · #{marker.call(sept)}", "c-food", "cleared", true, "acc-geteilt"]

    # Next day: the job enters the occurrence at startup and the first run
    # sends it together with the expense that is no longer in the future.
    calls = RY.ynab_calls(world, 1) { world.restart("2026-10-04T10:00:00Z") }
    calls.should(eq [post_txns])
    oct = RY.value(world, "SELECT id FROM expenses WHERE recurring_id = #{rule} AND date = '2026-10-04'").to_i64
    RY.live(world).last(2).map { |t| [t[0], t[1], t[2], t[3]] }.should eq [
      ["2026-10-04", -5000, "Zukunft", "Gesamt 10,00 € · bezahlt von Anna · #{marker.call(ids["zukunft"])}"],
      ["2026-10-04", -25000, "Wocheneinkauf", "Gesamt 50,00 € · bezahlt von Anna · #{marker.call(oct)}"],
    ]
    config.call("summary, last_sync").should eq ["2 neu · 0 geändert · 0 gelöscht", "2026-10-04T10:00:00Z"]
    E2E::Database.count(world.app.db_path, "SELECT count(*) FROM ynab_sync WHERE ynab_txn_id != ''").should eq 11
  end

  scenario "transactions deleted by hand in YNAB", world do
    user = world.user
    user.login("Anna")
    by_hand = ->(payee : String) do
      world.app.ynab.all.find { |t| t.payee_name == payee && !t.deleted }.not_nil!.tap { |t| t.deleted = true }.id
    end
    # Changed in the app: the PATCH answer says "deleted", the next run
    # creates it again.
    old = by_hand.call("Bäcker")
    calls = RY.ynab_calls(world, 2) do
      RY.update(user, ids["baecker"], RY.form("Bäckerei", "2026-10-02", "9,00", anna, [anna, ben]))
    end
    calls.should(eq [patch_txns, post_txns])
    RY.live(world).last[1..3].should eq [-4500, "Bäckerei", "Gesamt 9,00 € · bezahlt von Anna · #{marker.call(ids["baecker"])}"]
    RY.value(world, "SELECT ynab_txn_id FROM ynab_sync WHERE expense_id = #{ids["baecker"]}").should_not eq old

    # Deleted in the app: YNAB answers 404, the account is checked once and
    # the transaction counts as deleted.
    kino = by_hand.call("Kino")
    calls = RY.ynab_calls(world, 2) do
      user.post("/ausgaben/#{ids["kino"]}/loeschen").status.should eq 303
    end
    calls.should(eq ["DELETE /v1/plans/plan-1/transactions/#{kino}", "GET /v1/plans/plan-1/accounts/acc-geteilt"])
    E2E::Database.count(world.app.db_path, "SELECT count(*) FROM ynab_sync WHERE expense_id = #{ids["kino"]}").should eq 0
    config.call("summary, error").should eq ["0 neu · 0 geändert · 1 gelöscht", ""]
  end
end
