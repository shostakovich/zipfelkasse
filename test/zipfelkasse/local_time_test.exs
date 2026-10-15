defmodule Zipfelkasse.LocalTimeTest do
  use ExUnit.Case, async: true

  alias Zipfelkasse.LocalTime

  test "converts between UTC and the local wall-clock time" do
    utc = ~U[2026-07-01 10:15:30.123456Z]
    local = LocalTime.from_utc(utc)

    assert local.microsecond == {123_456, 6}
    assert LocalTime.to_utc(local) == ~U[2026-07-01 10:15:30Z]
    assert LocalTime.date(utc) == NaiveDateTime.to_date(local)
  end

  # Santiago de Chile skips from 00:00 (−04:00) to 01:00 (−03:00) on 6 September 2026.
  defp santiago(erl) do
    local = NaiveDateTime.from_erl!(erl)

    cond do
      NaiveDateTime.before?(local, ~N[2026-09-06 00:00:00]) ->
        [local |> NaiveDateTime.add(4, :hour) |> NaiveDateTime.to_erl()]

      NaiveDateTime.before?(local, ~N[2026-09-06 01:00:00]) ->
        []

      true ->
        [local |> NaiveDateTime.add(3, :hour) |> NaiveDateTime.to_erl()]
    end
  end

  test "takes the end of a skipped hour for a time in it" do
    for local <- [~N[2026-09-06 00:00:00], ~N[2026-09-06 00:30:15]] do
      assert LocalTime.to_utc(local, &santiago/1) == ~U[2026-09-06 04:00:00Z]
    end

    assert LocalTime.to_utc(~N[2026-09-05 23:59:59], &santiago/1) == ~U[2026-09-06 03:59:59Z]
    assert LocalTime.to_utc(~N[2026-09-06 01:00:01], &santiago/1) == ~U[2026-09-06 04:00:01Z]
  end

  for {now, next} <- [
        {"2026-10-02 01:00:00", "2026-10-02 03:00:00"},
        {"2026-10-02 03:00:00", "2026-10-03 03:00:00"},
        {"2026-10-02 23:59:00", "2026-10-03 03:00:00"},
        {"2026-10-24 23:00:00", "2026-10-25 03:00:00"}
      ] do
    test "plans 03:00 after #{now} for #{next}" do
      assert LocalTime.next_at(NaiveDateTime.from_iso8601!(unquote(now)), ~T[03:00:00]) ==
               NaiveDateTime.from_iso8601!(unquote(next))
    end
  end

  test "counts the milliseconds until a local time" do
    assert LocalTime.ms_until(NaiveDateTime.add(LocalTime.now(), -60)) == 0
    assert LocalTime.ms_until(NaiveDateTime.add(LocalTime.now(), 60)) in 58_000..60_000
  end

  test "rounds the milliseconds up, so that a timer never fires early" do
    local = ~N[2026-07-01 03:00:00]
    utc = LocalTime.to_utc(local)

    assert LocalTime.ms_until(local, DateTime.add(utc, -1500, :microsecond)) == 2
    assert LocalTime.ms_until(local, DateTime.add(utc, -1, :microsecond)) == 1
    assert LocalTime.ms_until(local, utc) == 0
  end
end
