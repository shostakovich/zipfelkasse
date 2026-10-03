module Zipfelkasse::Web
  # Categories can be named freely, so the icon is found by (German)
  # keywords; the first match wins.
  CATEGORY_ICONS = [
    {"cart", %w(lebensmittel einkauf supermarkt drogerie)},
    {"utensils", %w(restaurant essen café cafe gastro lieferdienst)},
    {"key", %w(miete wohnung)},
    {"zap", %w(nebenkosten strom wasser heizung energie)},
    {"home", %w(haushalt möbel garten reparatur)},
    {"car", %w(transport auto bahn tank taxi parken fahrt öpnv)},
    {"plane", %w(reise urlaub hotel flug)},
    {"ticket", %w(freizeit kino konzert sport ausflug hobby unterhaltung)},
    {"heart", %w(gesundheit apotheke arzt medizin)},
    {"gift", %w(geschenk spende)},
    {"shirt", %w(kleidung mode schuhe)},
    {"baby", %w(kind baby kita)},
    {"paw", %w(haustier tier)},
    {"graduation", %w(bildung schule kurs buch bücher)},
    {"phone", %w(handy internet telefon abo streaming)},
    {"shield", %w(versicherung)},
    {"receipt", %w(sonstig allgemein)},
  ]

  def self.category_icon(name : String) : String
    n = name.downcase
    CATEGORY_ICONS.each do |icon, keywords|
      return icon if keywords.any? { |kw| n.includes?(kw) }
    end
    "tag"
  end

  # The period label of an expense date in the list; both are calendar
  # dates, the week starts on Monday.
  def self.expense_period(d : Time, today : Time) : String
    last_month = first_of_last_month(today)
    if d > today
      "Bevorstehend"
    elsif d >= week_start(today)
      "Diese Woche"
    elsif d.year == today.year && d.month == today.month
      "Früher in diesem Monat"
    elsif d.year == last_month.year && d.month == last_month.month
      "Letzter Monat"
    elsif d.year == today.year
      "Früher in diesem Jahr"
    elsif d.year == today.year - 1
      "Letztes Jahr"
    else
      "Älter"
    end
  end

  # Like expense_period, but "Gestern" wins over the week.
  def self.activity_period(d : Time, today : Time) : String
    last_month = first_of_last_month(today)
    ws = week_start(today)
    if d >= today
      "Heute"
    elsif d == today - 1.day
      "Gestern"
    elsif d >= ws
      "Früher in dieser Woche"
    elsif d >= ws - 7.days
      "Letzte Woche"
    elsif d.year == today.year && d.month == today.month
      "Früher in diesem Monat"
    elsif d.year == last_month.year && d.month == last_month.month
      "Letzter Monat"
    elsif d.year == today.year
      "Früher in diesem Jahr"
    elsif d.year == today.year - 1
      "Letztes Jahr"
    else
      "Älter"
    end
  end

  def self.week_start(d : Time) : Time
    d - (d.day_of_week.value - 1).days
  end

  private def self.first_of_last_month(today : Time) : Time
    Time.utc(today.year, today.month, 1).shift(months: -1)
  end
end
