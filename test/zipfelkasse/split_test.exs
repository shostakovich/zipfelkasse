defmodule Zipfelkasse.SplitTest do
  use ExUnit.Case, async: true

  alias Zipfelkasse.Split

  @max 1_000_000_000_000

  defp parts(pairs),
    do: Enum.map(pairs, fn {id, weight} -> %{participant_id: id, weight: weight} end)

  defp amounts({:ok, shares}), do: Map.new(shares, &{&1.participant_id, &1.amount_cents})

  describe "split/4" do
    for {name, mode, total, pairs, want} <- [
          {"equal even", :equal, 900, [{1, 1}, {2, 1}, {3, 1}], %{1 => 300, 2 => 300, 3 => 300}},
          {"equal remainder to smallest ID", :equal, 1000, [{3, 1}, {1, 1}, {2, 1}],
           %{1 => 334, 2 => 333, 3 => 333}},
          {"equal two cents remainder", :equal, 1001, [{1, 0}, {2, 0}, {3, 0}],
           %{1 => 334, 2 => 334, 3 => 333}},
          {"equal one person", :equal, 1234, [{7, 1}], %{7 => 1234}},
          {"equal 1 cent among 3", :equal, 1, [{1, 1}, {2, 1}, {3, 1}],
           %{1 => 1, 2 => 0, 3 => 0}},
          {"shares 2:1", :shares, 900, [{1, 2}, {2, 1}], %{1 => 600, 2 => 300}},
          {"shares largest remainder", :shares, 1000, [{1, 1}, {2, 2}], %{1 => 333, 2 => 667}},
          {"shares with zero", :shares, 1000, [{1, 1}, {2, 0}], %{1 => 1000, 2 => 0}},
          {"percent", :percent, 1000, [{1, 3333}, {2, 3333}, {3, 3334}],
           %{1 => 333, 2 => 333, 3 => 334}},
          {"percent remainder by largest remainder", :percent, 101, [{1, 5000}, {2, 5000}],
           %{1 => 51, 2 => 50}},
          {"percent 70/30", :percent, 1999, [{1, 7000}, {2, 3000}], %{1 => 1399, 2 => 600}},
          {"amounts", :amount, 1000, [{1, 250}, {2, 750}], %{1 => 250, 2 => 750}}
        ] do
      test name do
        {:ok, shares} = result = Split.split(unquote(mode), unquote(total), parts(unquote(pairs)))

        assert amounts(result) == unquote(Macro.escape(want))
        assert shares |> Enum.map(& &1.amount_cents) |> Enum.sum() == unquote(total)
        ids = Enum.map(shares, & &1.participant_id)
        assert ids == Enum.uniq(Enum.sort(ids))
      end
    end
  end

  describe "split/4 rotating ties" do
    three = [{3, 1}, {1, 1}, {2, 1}]

    for {name, mode, total, pairs, rotation, want} <- [
          {"two people, even ID", :equal, 1001, [{1, 1}, {2, 1}], 10, %{1 => 501, 2 => 500}},
          {"two people, odd ID", :equal, 1001, [{1, 1}, {2, 1}], 11, %{1 => 500, 2 => 501}},
          {"three, start 0", :equal, 1000, three, 0, %{1 => 334, 2 => 333, 3 => 333}},
          {"three, start 1", :equal, 1000, three, 1, %{1 => 333, 2 => 334, 3 => 333}},
          {"three, start 2", :equal, 1000, three, 2, %{1 => 333, 2 => 333, 3 => 334}},
          {"three, start 3 = 0", :equal, 1000, three, 3, %{1 => 334, 2 => 333, 3 => 333}},
          {"two cents, start 1", :equal, 1001, three, 1, %{1 => 333, 2 => 334, 3 => 334}},
          {"two cents, start 2 (round-robin)", :equal, 1001, three, 2,
           %{1 => 334, 2 => 333, 3 => 334}},
          {"negative start value", :equal, 1000, three, -1, %{1 => 333, 2 => 333, 3 => 334}},
          {"largest remainder takes precedence", :shares, 5, [{1, 2}, {2, 1}, {3, 1}], 1,
           %{1 => 3, 2 => 1, 3 => 1}},
          {"only the tied rotate, start 0", :shares, 6, [{1, 2}, {2, 1}, {3, 1}], 0,
           %{1 => 3, 2 => 2, 3 => 1}},
          {"only the tied rotate, start 1", :shares, 6, [{1, 2}, {2, 1}, {3, 1}], 1,
           %{1 => 3, 2 => 1, 3 => 2}},
          {"percent 50/50", :percent, 101, [{1, 5000}, {2, 5000}], 7, %{1 => 50, 2 => 51}},
          {"amounts unaffected", :amount, 1000, [{1, 250}, {2, 750}], 1, %{1 => 250, 2 => 750}}
        ] do
      test name do
        result =
          Split.split(unquote(mode), unquote(total), parts(unquote(pairs)),
            rotation: unquote(rotation)
          )

        assert amounts(result) == unquote(Macro.escape(want))
      end
    end
  end

  test "stores weight 1 for equal splits" do
    {:ok, shares} = Split.split(:equal, 100, parts([{1, 0}, {2, 5}]))

    assert Enum.map(shares, & &1.weight) == [1, 1]
  end

  describe "split/4 errors" do
    for {name, mode, total, pairs, message} <- [
          {"no people", :equal, 100, [],
           "Mindestens eine Person muss an der Ausgabe beteiligt sein."},
          {"amount zero", :equal, 0, [{1, 1}], "Der Betrag muss größer als 0 sein."},
          {"amount negative", :equal, -5, [{1, 1}], "Der Betrag muss größer als 0 sein."},
          {"amount too large", :equal, @max + 1, [{1, 1}], "Der Betrag ist zu groß."},
          {"duplicate", :equal, 100, [{1, 1}, {1, 1}],
           "Eine Person ist in der Aufteilung doppelt aufgeführt."},
          {"invalid ID", :equal, 100, [{0, 1}], "Ungültige Person in der Aufteilung."},
          {"negative shares", :shares, 100, [{1, -1}, {2, 2}],
           "Anteile dürfen nicht negativ sein."},
          {"shares sum zero", :shares, 100, [{1, 0}],
           "Die Summe der Anteile muss größer als 0 sein."},
          {"shares too many", :shares, 100, [{1, 1_000_001}],
           "Anteile dürfen höchstens 1000000 sein."},
          {"percent over 100", :percent, 100, [{1, 10_001}],
           "Die Prozente müssen zusammen 100 % ergeben."},
          {"percent not 100", :percent, 100, [{1, 5000}, {2, 4000}],
           "Die Prozente müssen zusammen 100 % ergeben (aktuell 90,00 %)."},
          {"amounts sum wrong", :amount, 1000, [{1, 500}, {2, 400}],
           "Die Beträge müssen zusammen 10,00 € ergeben (aktuell 9,00 €)."}
        ] do
      test name do
        assert Split.split(unquote(mode), unquote(total), parts(unquote(pairs))) ==
                 {:error, unquote(message)}
      end
    end

    test "names the sum of amounts in the currency" do
      assert Split.split(:amount, 909, parts([{1, 1}]), original: 1000, currency: "jpy") ==
               {:error, "Die Beträge müssen zusammen 1.000 JPY ergeben (aktuell 1 JPY)."}
    end
  end

  describe "allocate/3" do
    for {name, total, weights, rotation, allocated} <- [
          {"gives the larger remainder the cent", 667, [600, 400], 0, [400, 267]},
          {"gives the extra cent to the first of three equal weights", 100, [1, 1, 1], 0,
           [34, 33, 33]},
          {"rotates the extra cent with the rotation", 100, [1, 1, 1], 4, [33, 34, 33]},
          {"gives two extra cents to the tied entries from the rotation on", 200, [1, 1, 1], 1,
           [66, 67, 67]},
          {"wraps a negative rotation around", 100, [1, 1, 1], -1, [33, 33, 34]},
          {"gives nothing to a weight of 0", 100, [2, 1, 1, 0], 1, [50, 25, 25, 0]},
          {"distributes the total in proportion to weights of any sum", 909, [333, 333, 334], 0,
           [303, 303, 303]},
          {"does not rotate when nothing is left over", 1000, [250, 750], 3, [250, 750]},
          {"gives nothing when all weights are 0", 5, [0, 0], 0, [0, 0]},
          {"gives nothing when the total is 0", 0, [1, 2], 5, [0, 0]},
          {"stays exact when total times weight exceeds 64 bits", @max, [999_999_999_999_999, 1],
           0, [@max, 0]},
          {"stays exact for weights beyond the maximum amount", @max, [@max * 100, @max * 100], 1,
           [div(@max, 2), div(@max, 2)]},
          {"rotates through eight tied entries", 7, List.duplicate(1, 8), 5,
           [1, 1, 1, 1, 0, 1, 1, 1]},
          {"rotates only the tied entries", 10, [3, 3, 1, 1, 1, 1], -7, [3, 3, 1, 1, 1, 1]}
        ] do
      test name do
        assert Split.allocate(unquote(total), unquote(weights), unquote(rotation)) ==
                 unquote(allocated)
      end
    end
  end

  describe "split/4 of a foreign amount" do
    @people [{3, 334}, {1, 333}, {2, 333}]

    test "splits the converted euro amount in proportion to the weights in the foreign currency" do
      assert Split.split(:amount, 909, parts(@people), original: 1000, currency: "USD") ==
               {:ok,
                [
                  %{participant_id: 1, weight: 333, amount_cents: 303},
                  %{participant_id: 2, weight: 333, amount_cents: 303},
                  %{participant_id: 3, weight: 334, amount_cents: 303}
                ]}
    end

    test "rotates a tied cent with the expense ID" do
      result =
        Split.split(:amount, 1001, parts([{1, 500}, {2, 500}]),
          original: 1000,
          currency: "USD",
          rotation: 1
        )

      assert amounts(result) == %{1 => 500, 2 => 501}
    end

    test "splits like any other in the other modes" do
      result =
        Split.split(:equal, 1000, parts(@people), original: 1100, currency: "USD", rotation: 1)

      assert amounts(result) == %{1 => 333, 2 => 334, 3 => 333}
    end

    for {name, pairs, message} <- [
          {"weights that fall short of the amount", [{1, 600}, {2, 300}],
           "Die Beträge müssen zusammen 10,00 USD ergeben (aktuell 9,00 USD)."},
          {"a single weight that falls short", [{1, 909}],
           "Die Beträge müssen zusammen 10,00 USD ergeben (aktuell 9,09 USD)."},
          {"a negative weight", [{1, -1}, {2, 1001}], "Anteile dürfen nicht negativ sein."},
          {"weights whose sum overflows 64 bits", [{1, 2 ** 62}, {2, 2 ** 62}, {3, 2 ** 62}],
           "Der Betrag ist zu groß."}
        ] do
      test "refuses #{name}" do
        assert Split.split(:amount, 909, parts(unquote(pairs)), original: 1000, currency: "USD") ==
                 {:error, unquote(message)}
      end
    end
  end

  test "names the split modes by their stored keys" do
    assert Split.modes() == [:equal, :shares, :percent, :amount]
  end

  describe "parse_weight/3" do
    for {text, shares} <- [{"5", 5}, {" 5 ", 5}, {"+5", 5}, {"-3", -3}, {"\t5", 5}] do
      test "reads #{inspect(text)} as #{shares} shares" do
        assert Split.parse_weight(:shares, "EUR", unquote(text)) == {:ok, unquote(shares)}
      end
    end

    for text <- ["1.5", "", "x"] do
      test "refuses #{inspect(text)} as shares" do
        assert Split.parse_weight(:shares, "EUR", unquote(text)) ==
                 {:error, "Anteile müssen ganze Zahlen sein („#{unquote(text)}“)."}
      end
    end

    test "reads amounts in the minor unit of the currency and percentages in basis points" do
      assert Split.parse_weight(:amount, "JPY", "1.500") == {:ok, 1500}
      assert Split.parse_weight(:percent, "JPY", "33,3") == {:ok, 3330}
    end

    test "ignores the text of an equal split" do
      assert Split.parse_weight(:equal, "JPY", "xyz") == {:ok, 0}
    end
  end

  test "weights are amounts in the decimals of the currency, percentages with 2 and whole shares" do
    assert Split.weight_decimals(:amount, "KWD") == 3
    assert Split.weight_decimals(:percent, "KWD") == 2
    assert Split.weight_decimals(:shares, "KWD") == 0
  end
end
