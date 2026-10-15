defmodule Zipfelkasse.DatesTest do
  use ExUnit.Case, async: true

  alias Zipfelkasse.{Dates, LocalTime}

  describe "next_occurrence/3" do
    for {name, frequency, anchor, day, want} <- [
          {"weekly", :weekly, "2026-01-05", "2026-01-05", "2026-01-12"},
          {"weekly across year boundary", :weekly, "2025-12-29", "2025-12-30", "2026-01-05"},
          {"weekly before anchor", :weekly, "2026-03-01", "2026-01-01", "2026-03-01"},
          {"monthly simple", :monthly, "2026-01-15", "2026-01-15", "2026-02-15"},
          {"monthly Jan 31 → Feb 28", :monthly, "2026-01-31", "2026-01-31", "2026-02-28"},
          {"monthly Jan 31 → Feb 29 leap year", :monthly, "2028-01-31", "2028-01-31",
           "2028-02-29"},
          {"monthly back to anchor after February", :monthly, "2026-01-31", "2026-02-28",
           "2026-03-31"},
          {"monthly April 30", :monthly, "2026-01-31", "2026-03-31", "2026-04-30"},
          {"monthly December → January", :monthly, "2026-12-31", "2026-12-31", "2027-01-31"},
          {"monthly mid-period", :monthly, "2026-01-10", "2026-05-20", "2026-06-10"},
          {"monthly before anchor", :monthly, "2026-05-10", "2026-01-01", "2026-05-10"},
          {"yearly", :yearly, "2026-03-15", "2026-03-15", "2027-03-15"},
          {"yearly Feb 29", :yearly, "2028-02-29", "2028-02-29", "2029-02-28"},
          {"yearly Feb 29 back in leap year", :yearly, "2028-02-29", "2031-03-01", "2032-02-29"}
        ] do
      test name do
        assert Dates.next_occurrence(
                 unquote(frequency),
                 Date.from_iso8601!(unquote(anchor)),
                 Date.from_iso8601!(unquote(day))
               ) ==
                 Date.from_iso8601!(unquote(want))
      end
    end
  end

  test "computes monthly occurrences from the anchor day" do
    anchor = ~D[2026-01-31]

    assert Enum.map(0..4, &Dates.occurrence(:monthly, anchor, &1)) ==
             [~D[2026-01-31], ~D[2026-02-28], ~D[2026-03-31], ~D[2026-04-30], ~D[2026-05-31]]
  end

  test "computes occurrences before the anchor and far behind it" do
    anchor = ~D[2026-01-31]

    for {n, monthly, yearly, weekly} <- [
          {-1, ~D[2025-12-31], ~D[2025-01-31], ~D[2026-01-24]},
          {-2, ~D[2025-11-30], ~D[2024-01-31], ~D[2026-01-17]},
          {-13, ~D[2024-12-31], ~D[2013-01-31], ~D[2025-11-01]},
          {-25, ~D[2023-12-31], ~D[2001-01-31], ~D[2025-08-09]},
          {13, ~D[2027-02-28], ~D[2039-01-31], ~D[2026-05-02]},
          {25, ~D[2028-02-29], ~D[2051-01-31], ~D[2026-07-25]},
          {0, ~D[2026-01-31], ~D[2026-01-31], ~D[2026-01-31]}
        ] do
      assert Dates.occurrence(:monthly, anchor, n) == monthly
      assert Dates.occurrence(:yearly, anchor, n) == yearly
      assert Dates.occurrence(:weekly, anchor, n) == weekly
    end
  end

  describe "parse/1" do
    for {text, day} <- [
          {"2026-10-02", ~D[2026-10-02]},
          {"02.10.2026", ~D[2026-10-02]},
          {"2.10.2026", ~D[2026-10-02]},
          {" 2026-10-02 ", ~D[2026-10-02]},
          {"2000-01-01", ~D[2000-01-01]},
          {"2100-12-31", ~D[2100-12-31]},
          {"02.1.2026", ~D[2026-01-02]},
          {"2.01.2026", ~D[2026-01-02]},
          {"2028-02-29", ~D[2028-02-29]},
          {"29.02.2028", ~D[2028-02-29]},
          {"\t2026-10-02 ", ~D[2026-10-02]}
        ] do
      test "reads #{inspect(text)} as #{day}" do
        assert Dates.parse(unquote(text)) == {:ok, unquote(Macro.escape(day))}
      end
    end

    for text <- [
          "yesterday",
          "2026-02-30",
          "2027-02-29",
          "31.4.2026",
          "2026-9-01",
          "2.1.26",
          "123.1.2026",
          "+2026-01-01",
          "+999-01-01",
          "0000-01-01",
          "2026-00-10",
          "2026-13-01",
          "00.01.2026",
          "2026-10-02x",
          "2026–10–02",
          "１２.1.2026",
          "١.1.2026"
        ] do
      test "rejects #{inspect(text)} as an invalid date" do
        assert Dates.parse(unquote(text)) == {:error, "Ungültiges Datum „#{unquote(text)}“."}
      end
    end

    for text <- ["", " 　 "] do
      test "asks for a date when given #{inspect(text)}" do
        assert Dates.parse(unquote(text)) == {:error, "Bitte ein Datum angeben."}
      end
    end

    for text <- ["1999-12-31", "2101-01-01", "0026-10-02", "9999-12-31"] do
      test "rejects #{text} as outside the years 2000 to 2100" do
        assert Dates.parse(unquote(text)) ==
                 {:error, "Das Datum „#{unquote(text)}“ liegt nicht zwischen 2000 und 2100."}
      end
    end
  end

  test "writes a date the German way" do
    assert Dates.format(~D[2026-10-02]) == "02.10.2026"
    assert Dates.format(~D[0026-10-02]) == "02.10.0026"
  end

  test "writes a moment in local time" do
    assert Dates.format_time(~N[2026-10-02 09:05:59]) == "02.10.2026, 09:05"

    utc = ~U[2026-10-01 23:30:00.000000Z]
    assert Dates.format_time(utc) == Dates.format_time(LocalTime.from_utc(utc))
  end
end
