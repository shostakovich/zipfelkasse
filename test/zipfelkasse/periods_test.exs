defmodule Zipfelkasse.PeriodsTest do
  use ExUnit.Case, async: true

  alias Zipfelkasse.Periods

  defp label(key), do: key |> Periods.heading() |> elem(0)

  describe "expense_heading/2 on Friday, 2026-10-02" do
    for {day, label} <- [
          {~D[2026-10-05], "Bevorstehend"},
          {~D[2026-10-02], "Diese Woche"},
          {~D[2026-10-01], "Diese Woche"},
          {~D[2026-09-28], "Diese Woche"},
          {~D[2026-09-27], "Letzter Monat"},
          {~D[2026-08-31], "Früher in diesem Jahr"},
          {~D[2025-12-31], "Letztes Jahr"},
          {~D[2024-06-01], "Älter"}
        ] do
      test "labels #{day} as #{inspect(label)}" do
        assert label(Periods.expense_heading(unquote(Macro.escape(day)), ~D[2026-10-02])) ==
                 unquote(label)
      end
    end

    test "labels an earlier day of the month as earlier in this month" do
      assert label(Periods.expense_heading(~D[2026-10-05], ~D[2026-10-20])) ==
               "Früher in diesem Monat"
    end

    test "calls December of the year before last month in January, not last year" do
      assert label(Periods.expense_heading(~D[2025-12-15], ~D[2026-01-20])) == "Letzter Monat"
    end
  end

  describe "activity_heading/2 on Tuesday, 2026-10-20" do
    for {day, label} <- [
          {~D[2026-10-20], "Heute"},
          {~D[2026-10-19], "Gestern"},
          {~D[2026-10-18], "Letzte Woche"},
          {~D[2026-10-12], "Letzte Woche"},
          {~D[2026-10-11], "Früher in diesem Monat"},
          {~D[2026-09-30], "Letzter Monat"},
          {~D[2026-01-01], "Früher in diesem Jahr"}
        ] do
      test "labels #{day} as #{inspect(label)}" do
        assert label(Periods.activity_heading(unquote(Macro.escape(day)), ~D[2026-10-20])) ==
                 unquote(label)
      end
    end

    test "labels an earlier day of this week as earlier this week" do
      assert label(Periods.activity_heading(~D[2026-10-19], ~D[2026-10-21])) ==
               "Früher in dieser Woche"
    end
  end

  test "finds the first day of a period by its label and back" do
    for {unit, label, first_day} <- [
          {:year, "2026", ~D[2026-01-01]},
          {:month, "2026-09", ~D[2026-09-01]},
          {:week, "2026-W01", ~D[2025-12-29]},
          {:week, "2026-W40", ~D[2026-09-28]},
          {:week, "2020-W53", ~D[2020-12-28]}
        ] do
      assert Periods.first_day(unit, label) == first_day
      assert Periods.label(unit, first_day) == label
    end

    assert Periods.first_day(:month, "nonsense") == nil
  end

  test "lists the labels from the first to the last period" do
    assert Periods.labels(:week, ~D[2026-09-30], ~D[2026-10-12]) == ~w(2026-W40 2026-W41 2026-W42)
    assert Periods.labels(:month, ~D[2025-11-30], ~D[2026-01-01]) == ~w(2025-11 2025-12 2026-01)
    assert Periods.labels(:year, ~D[2026-09-30], ~D[2026-09-29]) == []
  end

  test "finds the last day of a period" do
    assert Periods.last_day(:month, ~D[2024-02-10]) == ~D[2024-02-29]
    assert Periods.last_day(:week, ~D[2026-10-03]) == ~D[2026-10-04]
    assert Periods.last_day(:year, ~D[2026-10-03]) == ~D[2026-12-31]
  end

  test "moves labels by a year" do
    for {label, moved} <- [
          {"2025-09", "2026-09"},
          {"2025-W40", "2026-W40"},
          {"2025", "2026"},
          {"", ""},
          {"2020-W53", "2021-W52"},
          {"2025-W53", "2026-W53"}
        ] do
      assert Periods.shift_label(label, 1) == moved
    end
  end
end
