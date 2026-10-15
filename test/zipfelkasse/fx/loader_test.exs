defmodule Zipfelkasse.Fx.LoaderTest do
  use Zipfelkasse.DataCase

  @moduletag :capture_log

  alias Zipfelkasse.{FakeEcb, Fx, LocalTime}
  alias Zipfelkasse.Fx.{Ecb, Loader, Rate}

  @recent Ecb.recent()
  @history Ecb.history()

  # Most tests run on Friday, 2026-10-02 at 12:00, when the ECB has published up to Thursday.
  setup do
    %{ecb: FakeEcb.start(~D[2026-10-01])}
  end

  defp start_loader(ecb, now) do
    clock = start_supervised!({Agent, fn -> utc(now) end}, id: make_ref())

    loader =
      start_supervised!(
        {Loader, name: nil, base_url: ecb.url, clock: fn -> Agent.get(clock, & &1) end},
        id: make_ref()
      )

    %{loader: loader, clock: clock}
  end

  defp utc(local), do: local |> NaiveDateTime.from_iso8601!() |> LocalTime.to_utc()

  defp set_clock(%{clock: clock}, now), do: Agent.update(clock, fn _ -> utc(now) end)

  defp rate(loader, currency, date) do
    today = loader.clock |> Agent.get(& &1) |> LocalTime.date()
    Fx.rate(currency, date, today: today, loader: loader.loader)
  end

  defp files(ecb), do: ecb |> FakeEcb.requests() |> Enum.map(&elem(&1, 0))

  defp ecb!(currency, day), do: FakeEcb.rate!(currency, day)

  describe "rate lookups" do
    test "answer euros without loading anything", %{ecb: ecb} do
      loader = start_loader(ecb, "2026-10-02 12:00:00")

      assert {:ok, %Rate{currency: "EUR", source: :fixed, rate: 1.0}} =
               rate(loader, " eur ", ~D[2026-09-01])

      assert {:error, :no_rate} = rate(loader, "US1", ~D[2026-09-01])
      assert files(ecb) == []
    end

    test "load the 90-day file into an empty cache, then answer from it until the next publication",
         %{ecb: ecb} do
      loader = start_loader(ecb, "2026-10-02 12:00:00")

      usd = ecb!("USD", ~D[2026-10-01])

      assert {:ok, %Rate{currency: "USD", source: :ecb, date: ~D[2026-10-01], rate: ^usd}} =
               rate(loader, "usd", ~D[2026-10-01])

      assert [{@recent, ["zipfelkasse/" <> _agent]}] = FakeEcb.requests(ecb)

      assert {:ok, %Rate{date: ~D[2026-09-25], rate: jpy}} = rate(loader, "JPY", ~D[2026-09-27])
      assert jpy == ecb!("JPY", ~D[2026-09-25])
      assert {:ok, %Rate{date: ~D[2026-10-01]}} = rate(loader, "USD", ~D[2026-10-02])
      assert {:ok, %Rate{date: ~D[2026-10-01]}} = rate(loader, "GBP", ~D[2026-12-24])
      assert files(ecb) == [@recent]

      set_clock(loader, "2026-10-02 15:59:00")
      assert {:ok, %Rate{date: ~D[2026-10-01]}} = rate(loader, "USD", ~D[2026-10-02])
      assert files(ecb) == [@recent]

      FakeEcb.put(ecb, :last_day, ~D[2026-10-02])
      set_clock(loader, "2026-10-02 16:00:00")
      assert {:ok, %Rate{date: ~D[2026-10-02]}} = rate(loader, "USD", ~D[2026-10-02])
      assert files(ecb) == [@recent, @recent]
    end

    test "wait for the next weekday's publication after the Friday rates, also after a restart",
         %{ecb: ecb} do
      FakeEcb.put(ecb, :last_day, ~D[2026-10-02])
      loader = start_loader(ecb, "2026-10-02 17:00:00")
      assert {:ok, %Rate{date: ~D[2026-10-02]}} = rate(loader, "USD", ~D[2026-10-02])

      for now <- ["2026-10-03 10:00:00", "2026-10-04 23:00:00", "2026-10-05 15:59:00"] do
        day = now |> NaiveDateTime.from_iso8601!() |> NaiveDateTime.to_date()
        set_clock(loader, now)
        assert {:ok, %Rate{date: ~D[2026-10-02]}} = rate(loader, "USD", day)
        assert {:ok, %Rate{date: ~D[2026-10-02]}} = rate(start_loader(ecb, now), "USD", day)
      end

      assert files(ecb) == [@recent]

      FakeEcb.put(ecb, :last_day, ~D[2026-10-05])
      set_clock(loader, "2026-10-05 16:00:00")
      assert {:ok, %Rate{date: ~D[2026-10-05]}} = rate(loader, "USD", ~D[2026-10-05])
      assert files(ecb) == [@recent, @recent]
    end

    test "share one download between concurrent requests", %{ecb: ecb} do
      loader = start_loader(ecb, "2026-10-02 12:00:00")
      FakeEcb.block(ecb)

      lookups = for _n <- 1..2, do: Task.async(fn -> rate(loader, "USD", ~D[2026-10-01]) end)
      assert [{_first, nil}, {_second, nil}] = Task.yield_many(lookups, 100)
      FakeEcb.release(ecb)

      usd = ecb!("USD", ~D[2026-10-01])
      assert [{:ok, %Rate{rate: ^usd}}, {:ok, %Rate{rate: ^usd}}] = Task.await_many(lookups)
      assert files(ecb) == [@recent]
    end

    test "load the full history for a date before the 90 days, once", %{ecb: ecb} do
      loader = start_loader(ecb, "2026-10-02 12:00:00")
      usd = ecb!("USD", ~D[2024-01-03])
      gbp = ecb!("GBP", ~D[2024-03-01])
      chf = ecb!("CHF", ~D[2026-09-30])

      assert {:ok, %Rate{rate: ^usd}} = rate(loader, "USD", ~D[2024-01-03])
      assert {:ok, %Rate{date: ~D[2024-03-01], rate: ^gbp}} = rate(loader, "GBP", ~D[2024-03-02])
      assert {:ok, %Rate{rate: ^chf}} = rate(loader, "CHF", ~D[2026-09-30])
      assert {:error, :no_rate} = rate(loader, "USD", ~D[2023-11-20])
      assert {:error, :no_rate} = rate(loader, "RUB", ~D[2024-01-03])
      assert files(ecb) == [@history]
    end

    test "answer from the cache after a restart", %{ecb: ecb} do
      assert {:ok, _rate} = rate(start_loader(ecb, "2026-10-02 12:00:00"), "USD", ~D[2024-01-03])
      other = FakeEcb.start()
      restarted = start_loader(other, "2026-10-02 12:00:00")
      usd = ecb!("USD", ~D[2024-01-02])

      assert {:ok, %Rate{rate: ^usd}} = rate(restarted, "USD", ~D[2024-01-02])
      assert {:ok, %Rate{date: ~D[2026-10-01]}} = rate(restarted, "USD", ~D[2026-10-01])
      assert files(other) == []
    end

    test "do not load again shortly after a load for an unknown currency", %{ecb: ecb} do
      loader = start_loader(ecb, "2026-10-02 12:00:00")

      assert {:error, :no_rate} = rate(loader, "XYZ", ~D[2026-10-01])
      assert {:error, :no_rate} = rate(loader, "XYZ", ~D[2026-10-02])
      assert files(ecb) == [@recent]
    end

    test "prefer a manual rate from its date on and load nothing for it", %{ecb: ecb} do
      {:ok, _rate} = Fx.put_manual_rate(nil, %{currency: "USD", date: ~D[2026-09-30], rate: 1.2})
      {:ok, _rate} = Fx.put_manual_rate(nil, %{currency: "XYZ", date: ~D[2026-01-01], rate: 4.5})
      loader = start_loader(ecb, "2026-10-02 12:00:00")

      assert {:ok, %Rate{source: :manual, date: ~D[2026-09-30], rate: 1.2}} =
               rate(loader, "USD", ~D[2026-10-01])

      assert {:ok, %Rate{rate: 4.5}} = rate(loader, "XYZ", ~D[2026-06-01])
      assert files(ecb) == []

      usd = ecb!("USD", ~D[2026-09-29])
      assert {:ok, %Rate{source: :ecb, rate: ^usd}} = rate(loader, "USD", ~D[2026-09-29])
    end

    test "repeat a failed download's error until the cooldown is over", %{ecb: ecb} do
      loader = start_loader(ecb, "2026-10-02 12:00:00")
      FakeEcb.put(ecb, :failure, 503)

      assert {:error, {:unavailable, message}} = rate(loader, "USD", ~D[2026-10-01])
      assert message =~ "konnten nicht geladen werden (HTTP status 503)"

      FakeEcb.put(ecb, :failure, nil)
      assert {:error, {:unavailable, ^message}} = rate(loader, "USD", ~D[2026-10-01])
      assert files(ecb) == [@recent]

      set_clock(loader, "2026-10-02 12:15:00")
      assert {:ok, %Rate{date: ~D[2026-10-01]}} = rate(loader, "USD", ~D[2026-10-01])
      assert files(ecb) == [@recent, @recent]
    end

    for {failure, reason} <- [
          {500, "HTTP status 500"},
          {:broken, "xml: "},
          {:empty, "file contains no rates"}
        ] do
      test "report #{inspect(failure)} as a failed download", %{ecb: ecb} do
        FakeEcb.put(ecb, :failure, unquote(failure))
        loader = start_loader(ecb, "2026-10-02 12:00:00")

        assert {:error, {:unavailable, message}} = rate(loader, "USD", ~D[2026-10-01])
        assert message =~ "(#{unquote(reason)}"
      end
    end

    test "fall back to a cached rate when the download fails", %{ecb: ecb} do
      assert {:ok, _rate} = rate(start_loader(ecb, "2026-10-02 12:00:00"), "USD", ~D[2026-09-30])
      FakeEcb.put(ecb, :failure, 500)

      assert {:ok, %Rate{date: ~D[2026-10-01]}} =
               rate(start_loader(ecb, "2026-10-02 17:00:00"), "USD", ~D[2026-10-02])

      assert files(ecb) == [@recent, @recent]
    end
  end

  describe "refresh/1" do
    test "loads the 90-day file and gives the newest day", %{ecb: ecb} do
      loader = start_loader(ecb, "2026-10-02 12:00:00")

      assert Fx.refresh(loader.loader) == {:ok, ~D[2026-10-01]}
      assert Fx.refresh(loader.loader) == {:ok, ~D[2026-10-01]}
      assert files(ecb) == [@recent, @recent]
    end

    test "loads the full history when the cache is older than the 90-day file", %{ecb: ecb} do
      :ok = Fx.save_ecb_rates([%{currency: "USD", date: ~D[2026-06-01], rate: 1.1}])
      loader = start_loader(ecb, "2026-10-02 12:00:00")

      assert Fx.refresh(loader.loader) == {:ok, ~D[2026-10-01]}
      assert files(ecb) == [@history]
    end

    test "gives the error of a failed download", %{ecb: ecb} do
      FakeEcb.put(ecb, :failure, 500)
      loader = start_loader(ecb, "2026-10-02 12:00:00")

      assert {:error, "Die EZB-Kurse konnten nicht geladen werden (HTTP status 500)." <> _hint} =
               Fx.refresh(loader.loader)
    end
  end

  test "loads nothing without a base URL" do
    loader = start_supervised!({Loader, name: nil, base_url: nil})

    assert Loader.ensure(loader, ~D[2026-10-01]) == :ok

    assert {:error, "Die EZB-Kurse konnten nicht geladen werden" <> _rest} =
             Loader.refresh(loader)
  end

  describe "file_to_load/5" do
    @range Date.range(~D[2026-08-03], ~D[2026-10-01])
    @today ~D[2026-10-02]

    test "loads nothing for a cached day" do
      assert Loader.file_to_load(@range, ~D[2026-08-10], @today, nil, ~N[2026-10-02 12:00:00]) ==
               nil
    end

    test "loads the file that reaches a day before the cache" do
      assert Loader.file_to_load(@range, ~D[2026-07-09], @today, nil, ~N[2026-10-02 12:00:00]) ==
               @recent

      assert Loader.file_to_load(@range, ~D[2026-07-08], @today, nil, ~N[2026-10-02 12:00:00]) ==
               @history

      assert Loader.file_to_load(nil, ~D[2026-10-02], @today, nil, ~N[2026-10-02 12:00:00]) ==
               @recent
    end

    test "loads the 90-day file for a day after the cache once the ECB can have published" do
      assert Loader.file_to_load(@range, @today, @today, nil, ~N[2026-10-02 15:59:59]) == nil
      assert Loader.file_to_load(@range, @today, @today, nil, ~N[2026-10-02 16:00:00]) == @recent

      loaded_at = ~N[2026-10-02 16:30:00]

      assert Loader.file_to_load(@range, @today, @today, loaded_at, ~N[2026-10-02 17:00:00]) ==
               nil
    end
  end

  describe "published_since?/2" do
    for {since, now, published} <- [
          {"2026-10-02 12:00:00", "2026-10-02 16:00:00", true},
          {"2026-10-02 16:00:00", "2026-10-03 10:00:00", false},
          {"2026-10-02 16:00:00", "2026-10-05 15:59:59", false},
          {"2026-10-02 16:00:00", "2026-10-05 16:00:00", true},
          {"2026-10-03 12:00:00", "2026-10-05 16:00:00", true}
        ] do
      test "after #{since} by #{now}: #{published}" do
        assert Loader.published_since?(
                 NaiveDateTime.from_iso8601!(unquote(since)),
                 NaiveDateTime.from_iso8601!(unquote(now))
               ) == unquote(published)
      end
    end
  end
end
