defmodule Zipfelkasse.Activities.Changes do
  @moduledoc """
  What an update changed in an expense, as the activity log stores it: German field labels with
  the old and new value as shown, e.g. `Betrag: 30,00 € → 45,00 €`. Fields that look the same
  are not changes, so an expense saved unchanged has none.
  """

  alias Zipfelkasse.{Dates, Money, Split}

  @type change :: %{field: String.t(), old: String.t(), new: String.t()}

  @doc """
  The changes from `old` to `new`, expenses with their shares. `names` maps participant ids to
  names, `categories` category ids to names.
  """
  @spec expense(map(), map(), %{integer() => String.t()}, %{integer() => String.t()}) :: [
          change()
        ]
  def expense(old, new, names, categories) do
    old_split = split_summary(old, names)
    new_split = split_summary(new, names)

    [
      {"Art", kind(old), kind(new)},
      {"Titel", old.title, new.title},
      {"Betrag", Money.format_cents(old.amount_cents), Money.format_cents(new.amount_cents)},
      {"Originalbetrag", original(old), original(new)},
      {"Datum", Dates.format(old.date), Dates.format(new.date)}
    ]
    |> Kernel.++(category(old, new, categories))
    |> Kernel.++([
      {"Bezahlt von", names[old.paid_by_id], names[new.paid_by_id]},
      {"Notiz", old.notes, new.notes},
      {"Kurs", rate_summary(old), rate_summary(new)},
      {"Aufteilung", old_split, new_split}
    ])
    |> Kernel.++(weights(old, new, old_split == new_split, names))
    |> Enum.reject(fn {_field, old, new} -> old == new end)
    |> Enum.map(fn {field, old, new} -> %{field: field, old: old, new: new} end)
  end

  defp kind(%{reimbursement: true}), do: "Rückzahlung"
  defp kind(_expense), do: "Ausgabe"

  defp original(expense),
    do: Money.format_money(expense.original_amount, expense.original_currency)

  defp category(%{category_id: same}, %{category_id: same}, _categories), do: []

  defp category(old, new, categories),
    do: [
      {"Kategorie", Map.get(categories, old.category_id, "–"),
       Map.get(categories, new.category_id, "–")}
    ]

  defp rate_summary(expense) do
    if Money.eur?(expense.original_currency) do
      "–"
    else
      summary =
        "1 € = #{Money.format_rate(expense.fx_rate)} #{expense.original_currency}"

      case expense.fx_source do
        :ecb -> summary <> " (EZB)"
        :manual -> summary <> " (manuell)"
        nil -> summary
      end
    end
  end

  defp split_summary(expense, names) do
    Split.label(expense.split_mode) <>
      ": " <> summarize(expense.shares, names, &Money.format_cents(&1.amount_cents))
  end

  # Same cents, but other weights: shares 1:1 became 2:2.
  defp weights(_old, _new, false, _names), do: []

  defp weights(old, new, true, names) do
    label =
      case new.split_mode do
        :shares -> "Anteile"
        :percent -> "Prozente"
        :amount -> "Beträge"
        :equal -> "Gewichte"
      end

    [{label, weight_summary(old, names), weight_summary(new, names)}]
  end

  @doc ~s(The weights of the shares of `expense`, e.g. `"Anna 4,33 USD"` for a split by amounts.)
  @spec weight_summary(map(), %{integer() => String.t()}) :: String.t()
  def weight_summary(expense, names) do
    summarize(expense.shares, names, fn share ->
      case expense.split_mode do
        :percent -> Money.format_basis_points(share.weight)
        :amount -> Money.format_money(share.weight, expense.original_currency)
        _equal_or_shares -> Integer.to_string(share.weight)
      end
    end)
  end

  defp summarize(shares, names, value) do
    shares
    |> Enum.sort_by(& &1.participant_id)
    |> Enum.map_join(", ", &"#{names[&1.participant_id]} #{value.(&1)}")
  end
end
