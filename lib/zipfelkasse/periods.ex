defmodule Zipfelkasse.Periods do
  @moduledoc """
  Periods of the calendar. The headings that group the expense and activity lists, counted from
  today with weeks starting on Monday, and periods of a unit (`:year`, `:month`, ISO `:week`)
  labelled `"2026"`, `"2026-09"` and `"2026-W40"`, which sort as text.
  """

  @type unit :: :year | :month | :week

  @headings %{
    upcoming: {"Bevorstehend", "upcoming"},
    today: {"Heute", "today"},
    yesterday: {"Gestern", "yesterday"},
    this_week: {"Diese Woche", "this-week"},
    earlier_this_week: {"Früher in dieser Woche", "this-week"},
    last_week: {"Letzte Woche", "last-week"},
    earlier_this_month: {"Früher in diesem Monat", "this-month"},
    last_month: {"Letzter Monat", "last-month"},
    earlier_this_year: {"Früher in diesem Jahr", "this-year"},
    last_year: {"Letztes Jahr", "last-year"},
    older: {"Älter", "older"}
  }

  @doc "The heading of an expense dated `date`; expenses can lie ahead."
  @spec expense_heading(Date.t(), Date.t()) :: atom()
  def expense_heading(date, today) do
    cond do
      Date.after?(date, today) -> :upcoming
      not Date.before?(date, Date.beginning_of_week(today)) -> :this_week
      true -> month_heading(date, today)
    end
  end

  @doc "The heading of an activity on `date`."
  @spec activity_heading(Date.t(), Date.t()) :: atom()
  def activity_heading(date, today) do
    week = Date.beginning_of_week(today)

    cond do
      not Date.before?(date, today) -> :today
      date == Date.add(today, -1) -> :yesterday
      not Date.before?(date, week) -> :earlier_this_week
      not Date.before?(date, Date.add(week, -7)) -> :last_week
      true -> month_heading(date, today)
    end
  end

  defp month_heading(date, today) do
    last_month = today |> Date.beginning_of_month() |> Date.shift(month: -1)

    cond do
      {date.year, date.month} == {today.year, today.month} -> :earlier_this_month
      {date.year, date.month} == {last_month.year, last_month.month} -> :last_month
      date.year == today.year -> :earlier_this_year
      date.year == today.year - 1 -> :last_year
      true -> :older
    end
  end

  @doc ~s(The text and DOM id of a heading: `{"Diese Woche", "this-week"}`.)
  @spec heading(atom()) :: {String.t(), String.t()}
  def heading(key), do: Map.fetch!(@headings, key)

  @doc "The label of the period of `unit` that holds `date`."
  @spec label(unit(), Date.t()) :: String.t()
  def label(:year, date), do: year(date.year)
  def label(:month, date), do: year(date.year) <> "-" <> two(date.month)

  def label(:week, date) do
    {year, week} = :calendar.iso_week_number(Date.to_erl(date))
    year(year) <> "-W" <> two(week)
  end

  @doc "The labels of the periods from the one holding `first` to the one holding `last`."
  @spec labels(unit(), Date.t(), Date.t()) :: [String.t()]
  def labels(unit, first, last) do
    if Date.after?(first, last),
      do: [],
      else: labels(unit, start(unit, first), label(unit, last), [])
  end

  defp labels(unit, day, final, acc) do
    current = label(unit, day)
    acc = [current | acc]

    if current >= final,
      do: Enum.reverse(acc),
      else: labels(unit, next_start(unit, day), final, acc)
  end

  @doc "The last day of the period of `unit` that holds `date`."
  @spec last_day(unit(), Date.t()) :: Date.t()
  def last_day(unit, date), do: unit |> next_start(start(unit, date)) |> Date.add(-1)

  @doc "The first day of the period labelled `label`, or nil."
  @spec first_day(unit(), String.t()) :: Date.t() | nil
  def first_day(:year, label) do
    with [year] <- Regex.run(~r/\A(\d{1,4})/, label, capture: :all_but_first),
         do: new_date(year, 1, 1)
  end

  def first_day(:month, label) do
    with [year, month] <- Regex.run(~r/\A(\d{1,4})-(\d{1,2})/, label, capture: :all_but_first),
         %Date{} = january <- new_date(year, 1, 1),
         do: Date.shift(january, month: String.to_integer(month) - 1)
  end

  # 4 January always lies in week 1.
  def first_day(:week, label) do
    with [year, week] <- Regex.run(~r/\A(\d{1,4})-W(\d{1,2})/, label, capture: :all_but_first),
         %Date{} = fourth <- new_date(year, 1, 4),
         do: fourth |> Date.beginning_of_week() |> Date.add(7 * (String.to_integer(week) - 1))
  end

  defp new_date(year, month, day) do
    case Date.new(String.to_integer(year), month, day) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  @doc """
  Moves a label by `years`; `""` stays `""`. Week 53 becomes week 52 in a year without one.
  """
  @spec shift_label(String.t(), integer()) :: String.t()
  def shift_label(label, years) do
    case Integer.parse(String.slice(label, 0, 4)) do
      {year, ""} when year >= 0 ->
        year = year + years

        if String.ends_with?(label, "-W53") and not week_53?(year),
          do: year(year) <> "-W52",
          else: year(year) <> String.slice(label, 4..-1//1)

      _other ->
        label
    end
  end

  defp week_53?(year), do: :calendar.iso_week_number({year, 12, 28}) == {year, 53}

  defp start(:year, date), do: Date.new!(date.year, 1, 1)
  defp start(:month, date), do: Date.beginning_of_month(date)
  defp start(:week, date), do: Date.beginning_of_week(date)

  defp next_start(:year, date), do: Date.shift(date, year: 1)
  defp next_start(:month, date), do: Date.shift(date, month: 1)
  defp next_start(:week, date), do: Date.add(date, 7)

  defp year(year), do: year |> Integer.to_string() |> String.pad_leading(4, "0")
  defp two(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")
end
