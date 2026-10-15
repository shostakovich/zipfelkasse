defmodule Zipfelkasse.LocalTime do
  @moduledoc "The host's local time (`TZ` in the container), without a time zone database."

  @doc "The local wall-clock time."
  def now, do: NaiveDateTime.local_now()

  @doc "The local calendar date."
  def today, do: NaiveDateTime.to_date(now())

  @doc "The local wall-clock time of a UTC moment."
  def from_utc(%DateTime{} = utc) do
    utc
    |> DateTime.to_naive()
    |> NaiveDateTime.to_erl()
    |> :calendar.universal_time_to_local_time()
    |> NaiveDateTime.from_erl!(utc.microsecond)
  end

  @doc """
  The UTC moment of a local wall-clock time; the first one when it is ambiguous, the end of
  the gap when the clocks skip it.
  """
  def to_utc(%NaiveDateTime{} = local),
    do: to_utc(local, &:calendar.local_time_to_universal_time_dst/1)

  @doc false
  def to_utc(local, convert) do
    case local |> NaiveDateTime.to_erl() |> convert.() do
      [utc | _] -> utc |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC")
      [] -> to_utc(next_minute(local), convert)
    end
  end

  defp next_minute(local), do: NaiveDateTime.add(%{local | second: 0, microsecond: {0, 0}}, 60)

  @doc "The local calendar date of a UTC moment."
  def date(%DateTime{} = utc), do: utc |> from_utc() |> NaiveDateTime.to_date()

  @doc "The first local wall-clock time at `time` after `now`."
  def next_at(%NaiveDateTime{} = now, %Time{} = time) do
    today = NaiveDateTime.new!(NaiveDateTime.to_date(now), time)
    if NaiveDateTime.after?(today, now), do: today, else: NaiveDateTime.add(today, 1, :day)
  end

  @doc """
  The milliseconds from `now` until a local wall-clock time, rounded up so that a timer never
  fires before it; 0 when it has passed.
  """
  def ms_until(%NaiveDateTime{} = local, now \\ DateTime.utc_now()),
    do: max(div(DateTime.diff(to_utc(local), now, :microsecond) + 999, 1000), 0)
end
