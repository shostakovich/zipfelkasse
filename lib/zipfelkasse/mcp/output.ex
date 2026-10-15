defmodule Zipfelkasse.MCP.Output do
  @moduledoc """
  How tools show data: every amount twice, as `"1234.56"` (dot, no grouping) and in cents
  (`*_cents`); dates as `YYYY-MM-DD`; moments in the server time zone with their offset. Objects
  are keyword lists, so the keys keep a readable order; fields without a value are left out.
  """

  alias Zipfelkasse.Expenses.Expense
  alias Zipfelkasse.{LocalTime, Money}
  alias Zipfelkasse.MCP.Directory

  @doc ~s(Euro cents as "1234.56".)
  def eur(cents), do: Money.format_minor(cents, 2, separator: ".")

  @doc "A keyword list without its nil values."
  def compact(fields), do: Enum.reject(fields, fn {_key, value} -> is_nil(value) end)

  @doc "A person's balance."
  def balance(person, cents, status \\ nil),
    do: compact(person: person, balance: eur(cents), balance_cents: cents, status: status)

  @doc "An expense; `full?` adds foreign currency, notes and the split."
  def expense(%Expense{} = e, %Directory{} = directory, full?) do
    reimbursement = if e.reimbursement, do: reimbursement(e, directory), else: []

    compact(
      [
        id: e.id,
        date: Date.to_iso8601(e.date),
        title: e.title,
        category: e.category && e.category.name,
        paid_by: e.paid_by.name,
        amount: eur(e.amount_cents),
        amount_cents: e.amount_cents
      ] ++ reimbursement ++ if(full?, do: details(e, directory), else: [])
    )
  end

  defp reimbursement(e, directory) do
    recipient =
      case e.shares do
        [share | _] -> Directory.name(directory, share.participant_id)
        [] -> nil
      end

    [reimbursement: true, recipient: recipient]
  end

  defp details(e, directory) do
    foreign =
      if Expense.foreign?(e) do
        [
          original:
            Money.format_minor(e.original_amount, Money.decimals(e.original_currency),
              separator: "."
            ) <>
              " " <> e.original_currency,
          fx_rate: if(e.fx_rate != 0, do: e.fx_rate),
          fx_source: e.fx_source && Atom.to_string(e.fx_source)
        ]
      else
        []
      end

    split =
      if e.reimbursement or e.shares == [] do
        [split: if(not e.reimbursement, do: Atom.to_string(e.split_mode))]
      else
        [
          split: Atom.to_string(e.split_mode),
          shares:
            Enum.map(e.shares, fn share ->
              [
                person: Directory.name(directory, share.participant_id),
                amount: eur(share.amount_cents),
                amount_cents: share.amount_cents
              ]
            end)
        ]
      end

    foreign ++ [notes: if(e.notes != "", do: e.notes)] ++ split
  end

  @doc ~s(A UTC moment in the server time zone with its offset: "2026-10-03T12:00:00+02:00".)
  def local_time(%DateTime{} = utc) do
    local = LocalTime.from_utc(utc)
    offset = NaiveDateTime.diff(local, DateTime.to_naive(utc))
    text = Calendar.strftime(local, "%Y-%m-%dT%H:%M:%S")

    if offset == 0 do
      text <> "Z"
    else
      sign = if offset < 0, do: "-", else: "+"
      minutes = div(abs(offset), 60)
      text <> sign <> two(div(minutes, 60)) <> ":" <> two(rem(minutes, 60))
    end
  end

  defp two(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")

  @doc ~s(A period in words: "2026-01-01 to 2026-03-31", "from …", "until …" or "all time".)
  def range(nil, nil), do: "all time"
  def range(from, nil), do: "from #{Date.to_iso8601(from)}"
  def range(nil, to), do: "until #{Date.to_iso8601(to)}"
  def range(from, to), do: "#{Date.to_iso8601(from)} to #{Date.to_iso8601(to)}"
end
