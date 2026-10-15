defmodule Zipfelkasse.Expenses.FormTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset, only: [apply_changes: 1, get_field: 2]

  alias Zipfelkasse.Expenses.{Expense, ExpenseShare, Form}
  alias Zipfelkasse.Fx.Rate
  alias Zipfelkasse.Suggestions

  @anna %{id: 1, name: "Anna", archived_at: nil}
  @ben %{id: 2, name: "Ben", archived_at: nil}
  @cleo %{id: 3, name: "Cleo", archived_at: nil}
  @dora %{id: 4, name: "Dora", archived_at: ~U[2026-01-01 00:00:00.000000Z]}
  @people [@anna, @ben, @cleo, @dora]

  defp blank(opts \\ []),
    do: Form.new(@people, Keyword.merge([today: ~D[2026-10-01], participant_id: 1], opts))

  defp rows(form), do: Enum.map(form.rows, &{&1.participant_id, &1.selected, &1.weight})

  defp row_params(form, changes) do
    for {row, index} <- Enum.with_index(form.rows), into: %{} do
      {selected, weight} = Map.get(changes, row.participant_id, {row.selected, row.weight})

      {"#{index}",
       %{
         "participant_id" => "#{row.participant_id}",
         "selected" => "#{selected}",
         "weight" => weight
       }}
    end
  end

  defp change(form, params, opts \\ []),
    do: form |> Form.changeset(params, opts) |> apply_changes()

  defp input_errors(form) do
    {:error, changeset} = Form.input(form)
    Map.new(changeset.errors, fn {field, {message, _opts}} -> {field, message} end)
  end

  describe "a blank form" do
    test "is paid by the person, dated today and shared by every active person" do
      form = blank()

      assert {form.date, form.paid_by_id, form.title, form.currency, form.split_mode} ==
               {"2026-10-01", 1, "", "EUR", :equal}

      assert rows(form) == [{1, true, ""}, {2, true, ""}, {3, true, ""}]
    end

    test "is prefilled as a reimbursement from one person to another, archived ones included" do
      form = blank(reimbursement: true, from: 4, to: 2, amount_cents: 1250)

      assert {form.reimbursement, form.title, form.paid_by_id, form.amount} ==
               {true, "Rückzahlung", 4, "12,50"}

      assert rows(form) == [{1, false, ""}, {2, true, ""}, {3, false, ""}, {4, false, ""}]
    end
  end

  describe "the form of a saved expense" do
    defp expense(attrs) do
      struct(
        %Expense{
          id: 9,
          title: "Hotel",
          date: ~D[2026-09-30],
          category_id: 5,
          paid_by_id: 4,
          notes: "Zwei Nächte",
          amount_cents: 909,
          original_amount: 1000,
          original_currency: "USD",
          fx_rate: 1.1,
          fx_source: :ecb,
          split_mode: :percent,
          shares: [
            %ExpenseShare{participant_id: 1, weight: 3333, amount_cents: 303},
            %ExpenseShare{participant_id: 2, weight: 6667, amount_cents: 606}
          ]
        },
        attrs
      )
    end

    test "shows the values as entered, and the archived payer" do
      form = Form.from_expense(expense(%{}), @people)

      assert {form.expense_id, form.title, form.date, form.category_id, form.notes} ==
               {9, "Hotel", "2026-09-30", 5, "Zwei Nächte"}

      assert {form.currency, form.currency_other, form.amount, form.rate, form.rate_source} ==
               {"USD", "", "10,00", "1,1", :ecb}

      assert rows(form) == [
               {1, true, "33,33"},
               {2, true, "66,67"},
               {3, false, ""},
               {4, false, ""}
             ]
    end

    test "puts another currency in the free field and leaves the rate out for euros" do
      assert %{currency: "", currency_other: "THB"} =
               Form.from_expense(expense(%{original_currency: "THB"}), @people)

      form =
        Form.from_expense(
          expense(%{original_currency: "EUR", amount_cents: 1234, fx_source: nil}),
          @people
        )

      assert {form.amount, form.rate, form.rate_source} == {"12,34", "", nil}
    end

    test "writes the weights of each mode" do
      shares = [%ExpenseShare{participant_id: 1, weight: 2, amount_cents: 1}]

      assert hd(Form.from_expense(expense(%{split_mode: :shares, shares: shares}), @people).rows).weight ==
               "2"

      assert hd(Form.from_expense(expense(%{split_mode: :equal, shares: shares}), @people).rows).weight ==
               ""

      amount =
        Form.from_expense(
          expense(%{
            split_mode: :amount,
            original_currency: "JPY",
            shares: [%{hd(shares) | weight: 1500}]
          }),
          @people
        )

      assert hd(amount.rows).weight == "1500"

      percent =
        Form.from_expense(
          expense(%{
            split_mode: :percent,
            shares: [
              %{hd(shares) | weight: 5000},
              %{hd(shares) | participant_id: 2, weight: 3333}
            ]
          }),
          @people
        )

      assert Enum.map(Enum.take(percent.rows, 2), & &1.weight) == ["50", "33,33"]
    end
  end

  describe "changes as they are typed" do
    test "a new split mode fills in even weights for the selected people" do
      form =
        blank()
        |> change(%{"amount" => "10"})
        |> change(%{"rows" => row_params(blank(), %{3 => {false, ""}})})

      assert rows(change(form, %{"split_mode" => "shares"})) == [
               {1, true, "1"},
               {2, true, "1"},
               {3, false, ""}
             ]

      assert rows(change(form, %{"split_mode" => "percent"})) == [
               {1, true, "50"},
               {2, true, "50"},
               {3, false, ""}
             ]

      assert rows(change(form, %{"split_mode" => "amount"})) == [
               {1, true, "5,00"},
               {2, true, "5,00"},
               {3, false, ""}
             ]

      thirds = blank() |> change(%{"split_mode" => "percent"})
      assert rows(thirds) == [{1, true, "33,34"}, {2, true, "33,33"}, {3, true, "33,33"}]
    end

    test "a new selection refills percentages and amounts, but keeps shares" do
      percent = change(blank(), %{"split_mode" => "percent"})
      percent = change(percent, %{"rows" => row_params(percent, %{2 => {false, "33,33"}})})
      assert rows(percent) == [{1, true, "50"}, {2, false, ""}, {3, true, "50"}]

      shares = change(blank(), %{"split_mode" => "shares"})

      shares =
        change(shares, %{"rows" => row_params(shares, %{1 => {true, "3"}, 2 => {false, "1"}})})

      assert rows(shares) == [{1, true, "3"}, {2, false, "1"}, {3, true, "1"}]
    end

    test "turning a reimbursement on names it and keeps the first recipient who is not paying" do
      form = change(blank(), %{"reimbursement" => "true"})

      assert {form.title, rows(form)} ==
               {"Rückzahlung", [{1, false, ""}, {2, true, ""}, {3, false, ""}]}

      assert change(blank(), %{"title" => "Geld zurück", "reimbursement" => "true"}).title ==
               "Geld zurück"
    end

    test "turning a reimbursement off keeps the weights typed before" do
      form = %{change(blank(), %{"split_mode" => "percent"}) | reimbursement: true}

      assert rows(change(form, %{"reimbursement" => "false"})) == rows(form)
    end

    test "a reimbursement goes to the person selected last" do
      form = change(blank(), %{"reimbursement" => "true"})
      form = change(form, %{"rows" => row_params(form, %{3 => {true, ""}})})

      assert rows(form) == [{1, false, ""}, {2, false, ""}, {3, true, ""}]
    end

    test "ignores rows of people the form was not made for" do
      params =
        blank()
        |> row_params(%{})
        |> Map.put("9", %{"participant_id" => "77", "selected" => "true"})

      assert Enum.map(change(blank(), %{"rows" => params}).rows, & &1.participant_id) == [1, 2, 3]
    end

    test "a new currency drops the rate, a typed rate is manual" do
      rated = %{blank(currency: "USD") | currency: "USD", rate: "1,1", rate_source: :ecb}

      assert %{rate: "", rate_source: nil} = change(rated, %{"currency" => "GBP"})

      assert %{rate: "", rate_source: nil} =
               change(rated, %{"currency" => "", "currency_other" => "thb"})

      assert %{rate: "1,2", rate_source: :manual, rate_hint: "Von Hand eingetragener Kurs."} =
               change(rated, %{"rate" => "1,2"})

      assert %{rate: "1,1", rate_source: :ecb} =
               change(rated, %{"rate" => "1,1", "title" => "Taxi"})
    end

    test "a restore takes the params as they are, without what an edit implies" do
      params = %{
        "currency" => "USD",
        "rate" => "1,2",
        "rate_source" => "ecb",
        "split_mode" => "shares",
        "rows" => row_params(blank(), %{1 => {true, "2"}, 3 => {false, ""}})
      }

      restored = blank() |> Form.restore(params) |> apply_changes()

      assert {restored.currency, restored.rate, restored.rate_source} == {"USD", "1,2", :ecb}
      assert rows(restored) == [{1, true, "2"}, {2, true, ""}, {3, false, ""}]
    end

    test "asks for a rate lookup when the currency changes, or the date unless the rate is manual" do
      rated = %{blank() | currency: "USD", rate: "1,1", rate_source: :ecb}

      assert Form.rate_lookup?(Form.changeset(rated, %{"currency" => "GBP"}))
      assert Form.rate_lookup?(Form.changeset(rated, %{"date" => "2026-09-01"}))

      refute Form.rate_lookup?(
               Form.changeset(%{rated | rate_source: :manual}, %{"date" => "2026-09-01"})
             )

      refute Form.rate_lookup?(Form.changeset(rated, %{"title" => "Taxi"}))
      refute Form.rate_lookup?(Form.changeset(rated, %{"currency" => "EUR"}))

      refute Form.rate_lookup?(
               Form.changeset(rated, %{"currency" => "", "currency_other" => "US"})
             )
    end

    test "a new title suggests a category until one is chosen" do
      suggestions = Suggestions.build([{"Kaufland", 7}, {"Kino", 8}])

      form = change(blank(), %{"title" => "Kaufland"}, suggestions: suggestions)
      assert {form.category_id, form.category_suggested} == {7, true}

      form = change(form, %{"title" => "Kino"}, suggestions: suggestions)
      assert {form.category_id, form.category_suggested} == {8, true}

      form = change(form, %{"title" => "Tanken"}, suggestions: suggestions)
      assert {form.category_id, form.category_suggested} == {nil, false}

      form = change(form, %{"category_id" => "3"}, suggestions: suggestions)
      form = change(form, %{"title" => "Kaufland"}, suggestions: suggestions)
      assert {form.category_id, form.category_suggested} == {3, false}
    end

    test "selects everybody, or nobody when everybody is" do
      none = blank() |> Form.select_all() |> apply_changes()
      assert rows(none) == [{1, false, ""}, {2, false, ""}, {3, false, ""}]

      all = %{none | split_mode: :percent} |> Form.select_all() |> apply_changes()
      assert rows(all) == [{1, true, "33,34"}, {2, true, "33,33"}, {3, true, "33,33"}]
    end

    test "puts a looked-up rate in or clears it" do
      form = %{blank() | currency: "USD"}

      assert %{rate: "1,0912", rate_source: :ecb, rate_hint: "EZB-Kurs vom 30.09.2026."} =
               form
               |> Form.put_rate({:ok, %Rate{rate: 1.0912, source: :ecb, date: ~D[2026-09-30]}})
               |> apply_changes()

      assert %{rate_hint: "Manueller Kurs vom 01.09.2026."} =
               form
               |> Form.put_rate({:ok, %Rate{rate: 1.2, source: :manual, date: ~D[2026-09-01]}})
               |> apply_changes()

      assert %{
               rate: "",
               rate_source: nil,
               rate_hint: "Kein Kurs verfügbar. Kurs bitte von Hand eintragen."
             } =
               form |> Form.put_rate({:error, :no_rate}) |> apply_changes()
    end
  end

  describe "the preview" do
    test "splits the euro cents by the largest remainder, ties by the rotation" do
      form = %{blank() | amount: "10"}

      assert Form.preview(form, 0) == %{
               eur_cents: 1000,
               sum: nil,
               shares: %{1 => 334, 2 => 333, 3 => 333}
             }

      assert Form.preview(form, 1).shares == %{1 => 333, 2 => 334, 3 => 333}
    end

    test "converts a foreign amount at the rate" do
      form = %{blank() | currency: "", currency_other: "usd", amount: "100", rate: "1,0823"}

      assert %{eur_cents: 9240} = Form.preview(form, 0)
      assert %{eur_cents: nil, shares: %{}} = Form.preview(%{form | rate: ""}, 0)
    end

    test "takes an empty share as one share" do
      form = %{blank() | amount: "40", split_mode: :shares}

      form = %{
        form
        | rows:
            Enum.map(form.rows, &%{&1 | weight: if(&1.participant_id == 1, do: "2", else: "")})
      }

      assert Form.preview(form, 0).shares == %{1 => 2000, 2 => 1000, 3 => 1000}
    end

    for {weights, sum} <- [
          {["50", "50", ""], {:ok, "Summe 100 %."}},
          {["50", "20", "20"], {:error, "Summe 90 % – es fehlen 10 %."}},
          {["50", "50", "12,5"], {:error, "Summe 112,50 % – 12,50 zu viel %."}},
          {["50", "abc", ""], {:error, "Bitte nur gültige Zahlen eingeben."}},
          {["50", "-5", ""], {:error, "Bitte nur gültige Zahlen eingeben."}}
        ] do
      test "sums percentages #{inspect(weights)}" do
        form = with_weights(%{blank() | amount: "10", split_mode: :percent}, unquote(weights))

        assert Form.preview(form, 0).sum == unquote(Macro.escape(sum))
      end
    end

    for {currency, weights, sum} <- [
          {"EUR", ["5", "5", ""], {:ok, "Passt: 10,00 €."}},
          {"EUR", ["5", "", ""], {:error, "Noch 5,00 € offen."}},
          {"EUR", ["5", "6", ""], {:error, "1,00 € zu viel."}},
          {"JPY", ["600", "400", ""], {:ok, "Passt: 1000 JPY."}}
        ] do
      test "sums amounts #{inspect(weights)} in #{currency}" do
        form = %{blank() | amount: "10", split_mode: :amount, rate: "160"}

        form =
          if unquote(currency) == "EUR",
            do: form,
            else: %{form | currency: unquote(currency), amount: "1000"}

        assert Form.preview(with_weights(form, unquote(weights)), 0).sum ==
                 unquote(Macro.escape(sum))
      end
    end

    for {mode, weights} <- [percent: ["50 €", "50"], amount: ["10%", "10"], shares: ["+2", "1"]] do
      test "reads #{inspect(weights)} by #{mode} as saving does" do
        form =
          %{blank() | amount: "20", split_mode: unquote(mode)}
          |> with_weights(unquote(weights) ++ [""])
          |> Map.update!(:rows, &Enum.map(&1, fn row -> %{row | selected: row.weight != ""} end))

        saved? = match?({:ok, _input}, Form.input(form))
        previewed? = Form.preview(form, 0).sum != {:error, "Bitte nur gültige Zahlen eingeben."}

        assert {saved?, previewed?} == {unquote(mode) == :shares, unquote(mode) == :shares}
      end
    end

    test "shows nothing without an amount or a selected person" do
      assert Form.preview(blank(), 0) == %{eur_cents: nil, sum: nil, shares: %{}}

      assert Form.preview(
               blank() |> Form.select_all() |> apply_changes() |> Map.put(:amount, "5"),
               0
             ) ==
               %{eur_cents: 500, sum: nil, shares: %{}}
    end

    defp with_weights(form, weights) do
      %{form | rows: Enum.zip_with(form.rows, weights, &%{&1 | weight: &2})}
    end
  end

  describe "reading the input" do
    test "reads a valid form" do
      form = %{
        blank()
        | title: " Kino ",
          amount: "30",
          split_mode: :shares,
          notes: "Spätvorstellung "
      }

      assert Form.input(form) ==
               {:ok,
                %{
                  title: " Kino ",
                  date: ~D[2026-10-01],
                  category_id: nil,
                  paid_by_id: 1,
                  notes: "Spätvorstellung ",
                  reimbursement: false,
                  split_mode: :shares,
                  amount_cents: 3000,
                  original_amount: 3000,
                  original_currency: "EUR",
                  fx_rate: nil,
                  fx_source: nil,
                  parts: [
                    %{participant_id: 1, weight: 1},
                    %{participant_id: 2, weight: 1},
                    %{participant_id: 3, weight: 1}
                  ]
                }}
    end

    test "reads a foreign amount with its typed rate and a reimbursement equally" do
      form = %{
        blank(reimbursement: true, from: 1, to: 2)
        | currency: "JPY",
          amount: "1.500",
          rate: "160,5",
          rate_source: :manual
      }

      assert {:ok, input} = Form.input(form)

      assert Map.take(input, [
               :original_amount,
               :original_currency,
               :fx_rate,
               :fx_source,
               :split_mode,
               :parts
             ]) == %{
               original_amount: 1500,
               original_currency: "JPY",
               fx_rate: 160.5,
               fx_source: :manual,
               split_mode: :equal,
               parts: [%{participant_id: 2, weight: 0}]
             }
    end

    for {name, changes, field, message} <- [
          {"an invalid date", %{date: "morgen"}, :date, "Ungültiges Datum „morgen“."},
          {"a date out of range", %{date: "31.12.1999"}, :date,
           "Das Datum „31.12.1999“ liegt nicht zwischen 2000 und 2100."},
          {"an invalid currency", %{currency: "", currency_other: "euro"}, :currency,
           "Ungültige Währung „EURO“ – bitte einen dreistelligen ISO-Code wie USD angeben."},
          {"no currency", %{currency: "", currency_other: "  "}, :currency,
           "Bitte eine Währung angeben."},
          {"no amount", %{amount: "  "}, :amount, "Bitte einen Betrag eingeben."},
          {"an invalid amount", %{amount: "12,3,4"}, :amount, "Ungültiger Betrag „12,3,4“."},
          {"the amount 0", %{amount: "0"}, :amount, "Der Betrag muss größer als 0 sein."},
          {"a negative amount", %{amount: "-5"}, :amount, "Der Betrag muss größer als 0 sein."},
          {"too many decimals", %{amount: "1,234"}, :amount,
           "Höchstens 2 Nachkommastellen erlaubt."},
          {"decimals of yen", %{currency: "JPY", amount: "15,5"}, :amount,
           "Dieser Betrag darf keine Nachkommastellen haben."},
          {"an invalid rate", %{currency: "USD", rate: "abc"}, :rate,
           "Ungültiger Wechselkurs „abc“ – bitte eine Zahl größer als 0 angeben (Einheiten der Währung pro 1 €)."},
          {"the rate 0", %{currency: "USD", rate: "0"}, :rate,
           "Ungültiger Wechselkurs „0“ – bitte eine Zahl größer als 0 angeben (Einheiten der Währung pro 1 €)."},
          {"nobody selected", %{rows: []}, :rows,
           "Bitte mindestens eine Person ankreuzen, für die bezahlt wurde."},
          {"a reimbursement to nobody", %{reimbursement: true, rows: []}, :rows,
           "Eine Rückzahlung geht an genau eine Person – bitte genau einen Empfänger ankreuzen."},
          {"a reimbursement to three", %{reimbursement: true}, :rows,
           "Eine Rückzahlung geht an genau eine Person – bitte genau einen Empfänger ankreuzen."},
          {"an invalid percentage", %{split_mode: :percent, weights: ["100", "abc", ""]}, :rows,
           "Ben: Ungültige Prozentangabe „abc“."},
          {"a negative percentage", %{split_mode: :percent, weights: ["125", "-25", ""]}, :rows,
           "Ben: Negative Werte sind nicht erlaubt."},
          {"an invalid amount of a person", %{split_mode: :amount, weights: ["", "1,2,3", ""]},
           :rows, "Ben: Ungültiger Betrag „1,2,3“."},
          {"too many decimals of a person", %{split_mode: :amount, weights: ["", "", "0,001"]},
           :rows, "Cleo: Höchstens 2 Nachkommastellen erlaubt."},
          {"broken shares", %{split_mode: :shares, weights: ["", "1,5", ""]}, :rows,
           "Ben: Anteile müssen ganze Zahlen sein („1,5“)."},
          {"negative shares", %{split_mode: :shares, weights: ["", "-1", ""]}, :rows,
           "Ben: Negative Werte sind nicht erlaubt."}
        ] do
      test "refuses #{name}" do
        changes = unquote(Macro.escape(changes))

        form =
          struct(
            %{blank() | amount: "30", title: "Mein Titel"},
            Map.drop(changes, [:rows, :weights])
          )

        form =
          if Map.has_key?(changes, :rows),
            do: %{form | rows: Enum.map(form.rows, &%{&1 | selected: false})},
            else: form

        form = if weights = changes[:weights], do: with_weights(form, weights), else: form

        assert input_errors(form)[unquote(field)] == unquote(message)
      end
    end

    test "puts the errors of the expense on the fields of the form" do
      changeset =
        %Expense{}
        |> Expense.changeset(%{
          title: " ",
          parts: [],
          amount_cents: 0,
          date: ~D[2026-10-01],
          paid_by_id: 1
        })
        |> Map.put(:action, :insert)

      errors = Form.put_errors(blank(), changeset)

      assert errors.action == :insert

      assert {get_field(errors, :title), errors.errors |> Keyword.keys() |> Enum.sort()} ==
               {"", [:amount, :title]}
    end
  end

  test "offers the common currencies, euros first" do
    assert ["EUR" | others] = Form.common_currencies()
    assert length(others) == 13
  end
end
