defmodule Zipfelkasse.Dates do
  @moduledoc """
  Calendar dates as entered (`"2026-10-02"` or `"2.10.2026"`) and shown (`"02.10.2026"`), and
  the occurrences of a recurring date, always counted from its anchor: monthly from 31 January
  gives 28 (or 29) February, then 31 March again.
  """

  alias Zipfelkasse.LocalTime

  # Guards against typos ("0026") and endless recurrences from an absurd date.
  @years 2000..2100

  @type frequency :: :weekly | :monthly | :yearly

  @doc "Reads `YYYY-MM-DD` or `D.M.YYYY` with a year from 2000 to 2100."
  @spec parse(String.t()) :: {:ok, Date.t()} | {:error, String.t()}
  def parse(text) do
    text = String.trim(text)

    with {:text, true} <- {:text, text != ""},
         {:ok, date} <- read(text),
         {:range, true} <- {:range, date.year in @years} do
      {:ok, date}
    else
      {:text, false} ->
        {:error, "Bitte ein Datum angeben."}

      {:range, false} ->
        {:error, "Das Datum „#{text}“ liegt nicht zwischen #{@years.first} und #{@years.last}."}

      :error ->
        {:error, "Ungültiges Datum „#{text}“."}
    end
  end

  defp read(text) do
    fields =
      case Regex.run(~r/\A([0-9]{4})-([0-9]{2})-([0-9]{2})\z/, text, capture: :all_but_first) do
        [year, month, day] -> [year, month, day]
        nil -> german_fields(text)
      end

    with [year, month, day] <- fields,
         [year, month, day] = Enum.map([year, month, day], &String.to_integer/1),
         true <- year > 0,
         {:ok, date} <- Date.new(year, month, day) do
      {:ok, date}
    else
      _invalid -> :error
    end
  end

  defp german_fields(text) do
    case Regex.run(~r/\A([0-9]{1,2})\.([0-9]{1,2})\.([0-9]{4})\z/, text, capture: :all_but_first) do
      [day, month, year] -> [year, month, day]
      nil -> nil
    end
  end

  @doc ~s(A date as shown: `"02.10.2026"`.)
  @spec format(Date.t()) :: String.t()
  def format(%Date{} = date), do: Calendar.strftime(date, "%d.%m.%Y")

  @doc ~s(A moment as shown, in local time: `"02.10.2026, 14:05"`.)
  @spec format_time(DateTime.t() | NaiveDateTime.t()) :: String.t()
  def format_time(%DateTime{} = utc), do: utc |> LocalTime.from_utc() |> format_time()
  def format_time(%NaiveDateTime{} = local), do: Calendar.strftime(local, "%d.%m.%Y, %H:%M")

  @doc "The `n`-th occurrence after `anchor` (0 is the anchor itself, negative ones lie before)."
  @spec occurrence(frequency(), Date.t(), integer()) :: Date.t()
  def occurrence(:weekly, anchor, n), do: Date.add(anchor, 7 * n)
  def occurrence(:monthly, anchor, n), do: Date.shift(anchor, month: n)
  def occurrence(:yearly, anchor, n), do: Date.shift(anchor, year: n)

  @doc "The first occurrence after `day`; the anchor itself when `day` lies before it."
  @spec next_occurrence(frequency(), Date.t(), Date.t()) :: Date.t()
  def next_occurrence(frequency, anchor, day) do
    if Date.before?(day, anchor),
      do: anchor,
      else: first_after(frequency, anchor, day, max(estimate(frequency, anchor, day) - 1, 0))
  end

  defp estimate(:weekly, anchor, day), do: div(Date.diff(day, anchor), 7)
  defp estimate(:monthly, anchor, day), do: months_between(anchor, day)
  defp estimate(:yearly, anchor, day), do: div(months_between(anchor, day), 12)

  defp first_after(frequency, anchor, day, n) do
    date = occurrence(frequency, anchor, n)

    if Date.after?(date, day),
      do: date,
      else: first_after(frequency, anchor, day, n + 1)
  end

  defp months_between(a, b), do: (b.year - a.year) * 12 + b.month - a.month
end
