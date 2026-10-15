defmodule Zipfelkasse.FxTest do
  use Zipfelkasse.DataCase

  import Zipfelkasse.ActivityTexts
  import Zipfelkasse.Fixtures

  alias Zipfelkasse.{Expenses, Fx}
  alias Zipfelkasse.Fx.Rate

  @today ~D[2026-10-02]

  defp ecb!(currency, date, rate),
    do: Repo.insert!(%Rate{currency: currency, source: :ecb, date: date, rate: rate})

  defp rate(currency, date), do: Fx.rate(currency, date, today: @today)

  setup do
    ecb!("USD", ~D[2026-09-29], 1.10)
    ecb!("USD", ~D[2026-09-30], 1.11)
    ecb!("GBP", ~D[2026-09-30], 0.85)
    :ok
  end

  test "answers 1 for euros" do
    assert rate(" eur ", ~D[2026-09-01]) ==
             {:ok, %Rate{currency: "EUR", source: :fixed, date: ~D[2026-09-01], rate: 1.0}}
  end

  test "takes the latest ECB rate not after the date, within ten days" do
    assert {:ok, %Rate{currency: "USD", source: :ecb, date: ~D[2026-09-30], rate: 1.11}} =
             rate("usd", ~D[2026-10-02])

    assert {:ok, %Rate{date: ~D[2026-09-29], rate: 1.10}} = rate("USD", ~D[2026-09-29])

    assert {:ok, %Rate{date: ~D[2026-09-30]}} =
             Fx.rate("USD", ~D[2026-10-10], today: ~D[2026-10-10])

    assert Fx.rate("USD", ~D[2026-10-11], today: ~D[2026-10-11]) == {:error, :no_rate}
  end

  test "counts a date after today as today" do
    assert {:ok, %Rate{date: ~D[2026-09-30]}} =
             Fx.rate("USD", ~D[2026-12-24], today: ~D[2026-10-02])

    assert Fx.rate("USD", ~D[2026-12-24], today: ~D[2026-12-24]) == {:error, :no_rate}
  end

  test "has no rate for an unknown or invalid currency" do
    assert rate("CHF", ~D[2026-09-30]) == {:error, :no_rate}
    assert rate("US", ~D[2026-09-30]) == {:error, :no_rate}
    assert rate("", ~D[2026-09-30]) == {:error, :no_rate}
  end

  describe "manual rates" do
    setup do
      {:ok, _rate} =
        Fx.put_manual_rate(nil, %{currency: " usd ", date: ~D[2026-09-30], rate: 1.2})

      :ok
    end

    test "apply from their date on, however old, before the ECB rates" do
      assert {:ok, %Rate{source: :manual, rate: 1.2}} = rate("USD", ~D[2026-10-02])

      assert {:ok, %Rate{source: :manual, rate: 1.2}} =
               Fx.rate("USD", ~D[2027-05-01], today: ~D[2027-05-01])

      assert {:ok, %Rate{source: :ecb, rate: 1.10}} = rate("USD", ~D[2026-09-29])
    end

    test "replace a manual rate of the same day, but leave the ECB rate" do
      {:ok, _rate} = Fx.put_manual_rate(nil, %{currency: "USD", date: ~D[2026-09-30], rate: 1.21})

      assert [%Rate{currency: "USD", rate: 1.21}] = Fx.list_manual_rates()
      assert Repo.get_by!(Rate, currency: "USD", source: :ecb, date: ~D[2026-09-30]).rate == 1.11
    end

    test "are logged when saved and deleted" do
      {:ok, _rate} = Fx.put_manual_rate(nil, %{currency: "USD", date: ~D[2026-09-30], rate: 1.21})
      {:ok, _activity} = Fx.delete_manual_rate(nil, "usd", ~D[2026-09-30])

      assert activity_texts() == [
               "Manueller Kurs für USD ab 30.09.2026 gelöscht",
               "Manueller Kurs für USD ab 30.09.2026 gespeichert: 1 € = 1,21 USD",
               "Manueller Kurs für USD ab 30.09.2026 gespeichert: 1 € = 1,2 USD"
             ]
    end

    test "leave the ECB rate of their day when deleted" do
      {:ok, _activity} = Fx.delete_manual_rate(nil, "USD", ~D[2026-09-30])

      assert {:ok, %Rate{source: :ecb, rate: 1.11}} = rate("USD", ~D[2026-10-02])
      assert Fx.list_manual_rates() == []
    end

    test "cannot be deleted twice, or for a currency that has none" do
      {:ok, _activity} = Fx.delete_manual_rate(nil, "USD", ~D[2026-09-30])

      assert Fx.delete_manual_rate(nil, "USD", ~D[2026-09-30]) == {:error, :not_found}
      assert Fx.delete_manual_rate(nil, "GBP", ~D[2026-09-30]) == {:error, :not_found}
    end

    for {currency, rate, field, message} <- [
          {"EUR", 1.0, :currency, "Für Euro braucht es keinen Kurs."},
          {"US", 1.0, :currency, "Bitte einen dreistelligen Währungscode angeben (z. B. USD)."},
          {"USD", 0.0, :rate, "Der Kurs muss größer als 0 sein."},
          {"USD", -1.0, :rate, "Der Kurs muss größer als 0 sein."},
          {"USD", 1.0e10, :rate, "Der Kurs muss größer als 0 sein."},
          {"USD", nil, :rate, "Der Kurs muss größer als 0 sein."}
        ] do
      test "refuse #{currency} at #{inspect(rate)}" do
        assert {:error, changeset} =
                 Fx.put_manual_rate(nil, %{
                   currency: unquote(currency),
                   date: ~D[2026-09-30],
                   rate: unquote(rate)
                 })

        assert errors_on(changeset) == %{unquote(field) => [unquote(message)]}
      end
    end

    test "need a date" do
      assert {:error, changeset} = Fx.put_manual_rate(nil, %{currency: "USD", rate: 1.2})
      assert errors_on(changeset) == %{date: ["Bitte ein Datum angeben."]}
    end
  end

  describe "the ECB cache" do
    test "is described for the rates page" do
      :ok =
        Fx.save_ecb_rates([
          %{currency: "USD", date: ~D[2026-09-30], rate: 1.111},
          %{currency: "CHF", date: ~D[2026-09-30], rate: 0.94}
        ])

      {:ok, _rate} = Fx.put_manual_rate(nil, %{currency: "XYZ", date: ~D[2026-09-01], rate: 4.5})

      assert Fx.ecb_stats() == %{
               count: 4,
               currencies: 3,
               from: ~D[2026-09-29],
               to: ~D[2026-09-30]
             }

      assert Fx.ecb_range() == Date.range(~D[2026-09-29], ~D[2026-09-30])

      assert Enum.map(Fx.latest_ecb_rates(), &{&1.currency, &1.rate}) ==
               [{"CHF", 0.94}, {"GBP", 0.85}, {"USD", 1.111}]

      assert Fx.list_currencies() == ["CHF", "GBP", "USD", "XYZ"]
    end

    test "is empty without ECB rates" do
      Repo.delete_all(Rate)

      assert Fx.ecb_stats() == %{count: 0, currencies: 0, from: nil, to: nil}
      assert Fx.ecb_range() == nil
      assert Fx.latest_ecb_rates() == []
    end
  end

  test "lists the rates of the newest foreign expenses" do
    h = household()
    usd = create!(foreign(h, "Hotel", 10_000, "USD", 1.1, "2026-09-30", h.anna, [h.anna]))
    create!(equal(h, "Kino", 1000, "2026-10-01", h.anna, [h.anna]))
    chf = create!(foreign(h, "Bahn", 5000, "CHF", 0.94, "2026-09-29", h.anna, [h.anna]))

    {:ok, _deleted} =
      Expenses.delete_expense(
        nil,
        create!(foreign(h, "Weg", 100, "GBP", 0.8, "2026-10-01", h.anna, [h.anna]))
      )

    assert Fx.recent_expense_rates() == [
             %{
               expense_id: usd.id,
               title: "Hotel",
               currency: "USD",
               date: ~D[2026-09-30],
               rate: 1.1,
               source: :ecb
             },
             %{
               expense_id: chf.id,
               title: "Bahn",
               currency: "CHF",
               date: ~D[2026-09-29],
               rate: 0.94,
               source: :ecb
             }
           ]

    assert length(Fx.recent_expense_rates(1)) == 1
  end
end
