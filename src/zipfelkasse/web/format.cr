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

  def self.split_mode_label(mode : Domain::SplitMode) : String
    case mode
    in .equal?   then "Gleichmäßig"
    in .shares?  then "Nach Anteilen"
    in .percent? then "Nach Prozent"
    in .amount?  then "Nach Beträgen"
    end
  end

  def self.frequency_label(frequency : Domain::Frequency) : String
    case frequency
    in .weekly?  then "Wöchentlich"
    in .monthly? then "Monatlich"
    in .yearly?  then "Jährlich"
    end
  end

  def self.frequency_adverb(frequency : Domain::Frequency) : String
    case frequency
    in .weekly?  then "wöchentlich"
    in .monthly? then "monatlich"
    in .yearly?  then "jährlich"
    end
  end

  def self.category_icon(name : String) : String
    n = name.downcase
    CATEGORY_ICONS.each do |icon, keywords|
      return icon if keywords.any? { |kw| n.includes?(kw) }
    end
    "tag"
  end

  # The heading a list date falls under; the week starts on Monday. The
  # activity counts back from today, expenses can lie ahead.
  def self.period_label(d : Time, today : Time, activity = false) : String
    week = today.shift(days: 1 - today.day_of_week.value)
    last_month = Time.utc(today.year, today.month, 1).shift(months: -1)
    if activity
      return "Heute" if d >= today
      return "Gestern" if d == today.shift(days: -1)
      return "Früher in dieser Woche" if d >= week
      return "Letzte Woche" if d >= week.shift(days: -7)
    else
      return "Bevorstehend" if d > today
      return "Diese Woche" if d >= week
    end
    if {d.year, d.month} == {today.year, today.month}
      "Früher in diesem Monat"
    elsif {d.year, d.month} == {last_month.year, last_month.month}
      "Letzter Monat"
    elsif d.year == today.year
      "Früher in diesem Jahr"
    elsif d.year == today.year - 1
      "Letztes Jahr"
    else
      "Älter"
    end
  end
end
