defmodule Zipfelkasse.Activities.ChangesTest do
  use ExUnit.Case, async: true

  alias Zipfelkasse.Activities.Changes

  @names %{1 => "Anna", 2 => "Ben"}
  @categories %{1 => "Lebensmittel", 2 => "Restaurant"}

  @old %{
    reimbursement: false,
    title: "Pizza",
    amount_cents: 1000,
    original_amount: 1000,
    original_currency: "EUR",
    date: ~D[2026-09-01],
    category_id: 1,
    paid_by_id: 1,
    notes: "",
    fx_rate: 1.0,
    fx_source: nil,
    split_mode: :equal,
    shares: [
      %{participant_id: 2, weight: 1, amount_cents: 500},
      %{participant_id: 1, weight: 1, amount_cents: 500}
    ]
  }

  defp changes(new), do: Changes.expense(@old, Map.merge(@old, new), @names, @categories)

  test "an unchanged expense has no changes" do
    assert changes(%{}) == []
  end

  test "names each changed field with the values as shown" do
    assert changes(%{
             reimbursement: true,
             title: "Pizza & Wein",
             date: ~D[2026-09-02],
             category_id: nil,
             paid_by_id: 2,
             notes: "mit Lieferung"
           }) == [
             %{field: "Art", old: "Ausgabe", new: "Rückzahlung"},
             %{field: "Titel", old: "Pizza", new: "Pizza & Wein"},
             %{field: "Datum", old: "01.09.2026", new: "02.09.2026"},
             %{field: "Kategorie", old: "Lebensmittel", new: "–"},
             %{field: "Bezahlt von", old: "Anna", new: "Ben"},
             %{field: "Notiz", old: "", new: "mit Lieferung"}
           ]
  end

  test "shows the amount, the original amount, the rate and the split" do
    new = %{
      amount_cents: 917,
      original_amount: 1000,
      original_currency: "USD",
      fx_rate: 1.0912,
      fx_source: :ecb,
      split_mode: :shares,
      shares: [
        %{participant_id: 1, weight: 1, amount_cents: 459},
        %{participant_id: 2, weight: 1, amount_cents: 458}
      ]
    }

    assert changes(new) == [
             %{field: "Betrag", old: "10,00 €", new: "9,17 €"},
             %{field: "Originalbetrag", old: "10,00 €", new: "10,00 USD"},
             %{field: "Kurs", old: "–", new: "1 € = 1,0912 USD (EZB)"},
             %{
               field: "Aufteilung",
               old: "Gleichmäßig: Anna 5,00 €, Ben 5,00 €",
               new: "Nach Anteilen: Anna 4,59 €, Ben 4,58 €"
             }
           ]
  end

  for {mode, label, weights, old, new} <- [
        {:shares, "Anteile", {2, 2}, "Anna 1, Ben 1", "Anna 2, Ben 2"},
        {:percent, "Prozente", {5000, 5000}, "Anna 0,01 %, Ben 0,01 %",
         "Anna 50,00 %, Ben 50,00 %"},
        {:equal, "Gewichte", {2, 2}, "Anna 1, Ben 1", "Anna 2, Ben 2"}
      ] do
    test "lists the weights as #{label} when the cents stay the same" do
      {anna, ben} = unquote(weights)

      old = %{@old | split_mode: unquote(mode)}

      shares = [
        %{participant_id: 1, weight: anna, amount_cents: 500},
        %{participant_id: 2, weight: ben, amount_cents: 500}
      ]

      assert Changes.expense(old, %{old | shares: shares}, @names, @categories) == [
               %{field: unquote(label), old: unquote(old), new: unquote(new)}
             ]
    end
  end

  test "writes amount weights in the currency" do
    expense = %{
      split_mode: :amount,
      original_currency: "USD",
      shares: [%{participant_id: 1, weight: 433}]
    }

    assert Changes.weight_summary(expense, @names) == "Anna 4,33 USD"
  end

  test "names a manual rate" do
    old = %{@old | original_currency: "USD", fx_rate: 1.25, fx_source: :ecb}

    assert Changes.expense(old, %{old | fx_source: :manual}, @names, @categories) == [
             %{field: "Kurs", old: "1 € = 1,25 USD (EZB)", new: "1 € = 1,25 USD (manuell)"}
           ]
  end
end
