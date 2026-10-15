defmodule ZipfelkasseWeb.CategoryIcon do
  @moduledoc """
  The plush of an expense. Categories are named freely, so their plush is found by German
  keywords in the name; the first match wins, "tag" stands for the rest. A reimbursement shows
  banknotes.
  """

  @keywords [
    {"shopping-cart", ~w(lebensmittel einkauf supermarkt drogerie)},
    {"utensils", ~w(restaurant essen café cafe gastro lieferdienst)},
    {"key", ~w(miete wohnung)},
    {"zap", ~w(nebenkosten strom wasser heizung energie)},
    {"house", ~w(haushalt möbel garten reparatur)},
    {"car", ~w(transport auto bahn tank taxi parken fahrt öpnv)},
    {"plane", ~w(reise urlaub hotel flug)},
    {"ticket", ~w(freizeit kino konzert sport ausflug hobby unterhaltung)},
    {"heart", ~w(gesundheit apotheke arzt medizin)},
    {"gift", ~w(geschenk spende)},
    {"shirt", ~w(kleidung mode schuhe)},
    {"baby", ~w(kind baby kita)},
    {"paw-print", ~w(haustier tier)},
    {"graduation-cap", ~w(bildung schule kurs buch bücher)},
    {"smartphone", ~w(handy internet telefon abo streaming)},
    {"shield", ~w(versicherung)},
    {"receipt", ~w(sonstig allgemein)}
  ]

  @doc ~s(The plush of a category name: `"Lebensmittel"` is `"shopping-cart"`.)
  @spec for_category(String.t() | nil) :: String.t()
  def for_category(nil), do: "tag"

  def for_category(name) do
    name = String.downcase(name)

    Enum.find_value(@keywords, "tag", fn {icon, words} ->
      if Enum.any?(words, &String.contains?(name, &1)), do: icon
    end)
  end

  @doc "The plush of an expense, or a rule's template, with its category loaded."
  def for_expense(%{reimbursement: true}), do: "banknote"
  def for_expense(%{category: %{name: name}}), do: for_category(name)
  def for_expense(_expense), do: "tag"
end
