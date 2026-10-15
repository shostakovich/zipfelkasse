defmodule ZipfelkasseWeb.PeriodHeadings do
  @moduledoc """
  Stream rows under period headings (see `Zipfelkasse.Periods`), a page at a time: a heading
  goes in before the first row of its period, and a page that continues the period of the one
  before brings none.
  """

  alias Zipfelkasse.Periods

  @doc """
  The rows of `items` (by `row`) with their headings (by `heading`, a key of
  `Zipfelkasse.Periods.heading/1`), and the heading of the last one. `last` is the heading of the
  page before, nil for the first.
  """
  def rows(items, last, heading, row) do
    Enum.flat_map_reduce(items, last, fn item, last ->
      case heading.(item) do
        ^last -> {[row.(item)], last}
        key -> {[heading_row(key), row.(item)], key}
      end
    end)
  end

  defp heading_row(key) do
    {label, id} = Periods.heading(key)
    %{kind: :heading, dom_id: "group-" <> id, label: label}
  end
end
