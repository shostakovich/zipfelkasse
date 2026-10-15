defmodule Zipfelkasse.Fx.EcbTest do
  use ExUnit.Case, async: true

  alias Zipfelkasse.FakeEcb
  alias Zipfelkasse.Fx.Ecb

  @recent FakeEcb.file(Ecb.recent(), ~D[2026-10-02])

  describe "parse/1" do
    test "reads every rate of every day" do
      assert {:ok, rates} = Ecb.parse(@recent)
      days = rates |> Enum.map(& &1.date) |> Enum.uniq()

      assert length(rates) == length(days) * length(FakeEcb.currencies())
      assert {Enum.min(days, Date), Enum.max(days, Date)} == {~D[2026-07-06], ~D[2026-10-02]}

      assert [%{currency: "USD", date: ~D[2026-10-02], rate: usd}, %{currency: "JPY"} | _] = rates
      assert usd == FakeEcb.rate!("USD", ~D[2026-10-02])
    end

    test "rejects a cut-off file instead of reading fewer rates" do
      {at, _length} = :binary.match(@recent, "rate='")
      assert {:error, "xml: " <> _reason} = Ecb.parse(binary_part(@recent, 0, at + 12))
      assert {:error, "xml: " <> _reason} = Ecb.parse("<broken")
      assert {:error, "xml: " <> _reason} = Ecb.parse("")
    end

    test "rejects a day without a date and content after the document" do
      assert Ecb.parse(
               "<a><Cube><Cube time='2.10.2026'><Cube currency='USD' rate='1.1'/></Cube></Cube></a>"
             ) ==
               {:error, ~s(xml: date "2.10.2026")}

      assert Ecb.parse(@recent <> "<more/>") == {:error, "xml: content after the document"}
    end

    test "rejects a file without rates and skips currencies and rates it cannot read" do
      cubes = "<Cube currency='US' rate='1.1'/><Cube currency='GBP' rate='N/A'/>"

      assert Ecb.parse("<a><Cube><Cube time='2026-10-02'>#{cubes}</Cube></Cube></a>") ==
               {:error, "file contains no rates"}
    end

    test "refuses entities" do
      xml = ~s(<?xml version="1.0"?><!DOCTYPE a [<!ENTITY x "1.1">]><a>&x;</a>)
      assert {:error, "xml: " <> _reason} = Ecb.parse(xml)
    end
  end

  for {text, rate} <- [
        {"1.1298", 1.1298},
        {" 2 ", 2.0},
        {"N/A", nil},
        {"", nil},
        {"-1", nil},
        {"0", nil},
        {"NaN", nil},
        {"Inf", nil},
        {"2e12", nil}
      ] do
    test "reads #{inspect(text)} as #{inspect(rate)}" do
      assert Ecb.parse_rate(unquote(text)) == unquote(rate)
    end
  end
end
