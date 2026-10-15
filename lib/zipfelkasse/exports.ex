defmodule Zipfelkasse.Exports do
  @moduledoc """
  Downloads of the expenses, oldest first and without deleted ones, for a period (both ends
  inclusive, either open): a CSV for German Excel and a JSON file of everything, and a person's
  shares for YNAB as OFX and as YNAB's CSV, selected like the YNAB sync.

  Each export returns `%{filename, content_type, body}`; options `:now` (UTC) and `:today` (the
  local date of the file name).
  """

  alias Zipfelkasse.{Dates, Expenses, LocalTime, Money}
  alias Zipfelkasse.Expenses.Expense
  alias Zipfelkasse.{OrderedJSON, Participants, Settings, Split, Ynab}
  alias Zipfelkasse.Ynab.Posting

  @bom "﻿"
  @csv_header ~w(ID Datum Titel Kategorie) ++
                [
                  "Bezahlt von",
                  "Betrag (EUR)",
                  "Originalbetrag",
                  "Währung",
                  "Kurs",
                  "Art",
                  "Aufteilung",
                  "Notiz"
                ]

  @type period :: %{from: Date.t() | nil, to: Date.t() | nil}

  @doc """
  The period of the params `"from"` and `"to"`. Only an empty value means open; anything else
  must be a date.
  """
  @spec period(map()) :: {:ok, period()} | {:error, String.t()}
  def period(params) do
    with {:ok, from} <- date_param(params["from"]),
         {:ok, to} <- date_param(params["to"]) do
      if from && to && Date.before?(to, from),
        do: {:error, "„Bis“ liegt vor „Von“."},
        else: {:ok, %{from: from, to: to}}
    end
  end

  defp date_param(value) when value in [nil, ""], do: {:ok, nil}
  defp date_param(value) when is_binary(value), do: Dates.parse(value)
  defp date_param(_value), do: {:error, "Bitte ein Datum angeben."}

  @doc "Every expense with the shares of the people involved, for German Excel."
  def expenses_csv(period, opts \\ []) do
    expenses = expenses(period)
    people = involved(expenses)

    rows =
      for expense <- expenses do
        [
          Integer.to_string(expense.id),
          Dates.format(expense.date),
          cell(expense.title),
          cell(if(expense.category, do: expense.category.name, else: "")),
          cell(expense.paid_by.name),
          Money.format_minor(expense.amount_cents, 2),
          Money.format_minor(expense.original_amount, Money.decimals(expense.original_currency)),
          expense.original_currency,
          if(Expense.foreign?(expense), do: Money.format_rate(expense.fx_rate), else: ""),
          if(expense.reimbursement, do: Expense.reimbursement_title(), else: "Ausgabe"),
          Split.label(expense.split_mode),
          cell(expense.notes)
        ] ++ Enum.map(people, &share_cell(expense, &1.id))
      end

    body = @bom <> csv([@csv_header ++ Enum.map(people, &"Anteil #{&1.name}") | rows], ";")
    download("ausgaben", period, "csv", "text/csv; charset=utf-8", body, opts)
  end

  defp share_cell(expense, participant_id) do
    if Enum.any?(expense.shares, &(&1.participant_id == participant_id)),
      do: Money.format_minor(Expense.share_of(expense, participant_id), 2),
      else: ""
  end

  defp involved(expenses) do
    ids =
      for expense <- expenses,
          id <- [expense.paid_by_id | Enum.map(expense.shares, & &1.participant_id)],
          into: MapSet.new(),
          do: id

    Enum.filter(Participants.list_participants(:all), &MapSet.member?(ids, &1.id))
  end

  @doc "Everything about the expenses, with all people, as JSON."
  def expenses_json(period, opts \\ []) do
    people = Participants.list_participants(:all)
    names = Map.new(people, &{&1.id, &1.name})

    document =
      [group: Settings.group_name(), exported_at: timestamp(now(opts))] ++
        period_dates(period) ++
        [
          currency: "EUR",
          participants:
            Enum.map(people, &[id: &1.id, name: &1.name, archived: not is_nil(&1.archived_at)]),
          expenses: Enum.map(expenses(period), &json_expense(&1, names))
        ]

    body = OrderedJSON.format!(document)
    download("ausgaben", period, "json", "application/json; charset=utf-8", body, opts)
  end

  defp period_dates(period) do
    for {key, date} <- [from: period.from, to: period.to], date, do: {key, Date.to_iso8601(date)}
  end

  defp json_expense(expense, names) do
    [
      id: expense.id,
      date: Date.to_iso8601(expense.date),
      title: expense.title,
      category_id: expense.category_id,
      category: if(expense.category, do: expense.category.name, else: ""),
      paid_by: expense.paid_by_id,
      paid_by_name: expense.paid_by.name,
      amount_cents: expense.amount_cents,
      is_reimbursement: expense.reimbursement,
      split_mode: Atom.to_string(expense.split_mode),
      original_amount_minor: expense.original_amount,
      original_currency: expense.original_currency,
      fx_rate: expense.fx_rate,
      fx_source: fx_source(expense.fx_source),
      notes: expense.notes,
      recurring_id: expense.recurring_expense_id,
      shares:
        Enum.map(expense.shares, fn share ->
          [
            participant_id: share.participant_id,
            name: Map.get(names, share.participant_id, ""),
            weight: share.weight,
            amount_cents: share.amount_cents
          ]
        end),
      created_at: timestamp(expense.inserted_at),
      updated_at: timestamp(expense.updated_at)
    ]
  end

  # The values of the file format, as people's scripts read them.
  defp fx_source(:ecb), do: "ezb"
  defp fx_source(:manual), do: "manuell"
  defp fx_source(nil), do: ""

  @doc """
  A person's postings as an OFX 1.02 statement for YNAB's file import. Without a period, it spans
  the postings, or today.
  """
  def ynab_ofx(participant, period, opts \\ []) do
    postings = postings(participant.id, period, opts)
    now = now(opts)
    local_today = LocalTime.date(now)
    from = period.from || first_date(postings) || local_today
    to = period.to || last_date(postings) || local_today
    total = postings |> Enum.map(&(-&1.amount_cents)) |> Enum.sum()

    lines =
      ofx_head(now, "ZIPFELKASSE-#{participant.id}", from, to) ++
        Enum.flat_map(postings, &ofx_transaction/1) ++
        [
          "</BANKTRANLIST>",
          "<LEDGERBAL>",
          "<BALAMT>" <> Money.format_minor(total, 2, separator: "."),
          "<DTASOF>" <> ofx_date(to),
          "</LEDGERBAL>",
          "</STMTRS>",
          "</STMTTRNRS>",
          "</BANKMSGSRSV1>",
          "</OFX>"
        ]

    body = Enum.map_join(lines, &(&1 <> "\r\n"))
    download("ynab", period, "ofx", "application/x-ofx", body, opts)
  end

  defp first_date([]), do: nil
  defp first_date([posting | _]), do: posting.date

  defp last_date([]), do: nil
  defp last_date(postings), do: List.last(postings).date

  defp ofx_head(now, account, from, to) do
    ~w(OFXHEADER:100 DATA:OFXSGML VERSION:102 SECURITY:NONE ENCODING:UTF-8 CHARSET:NONE
       COMPRESSION:NONE OLDFILEUID:NONE NEWFILEUID:NONE) ++
      [
        "",
        "<OFX>",
        "<SIGNONMSGSRSV1>",
        "<SONRS>",
        "<STATUS>",
        "<CODE>0",
        "<SEVERITY>INFO",
        "</STATUS>",
        "<DTSERVER>" <> Calendar.strftime(now, "%Y%m%d%H%M%S"),
        "<LANGUAGE>GER",
        "</SONRS>",
        "</SIGNONMSGSRSV1>",
        "<BANKMSGSRSV1>",
        "<STMTTRNRS>",
        "<TRNUID>1",
        "<STATUS>",
        "<CODE>0",
        "<SEVERITY>INFO",
        "</STATUS>",
        "<STMTRS>",
        "<CURDEF>EUR",
        "<BANKACCTFROM>",
        "<BANKID>ZIPFEL",
        "<ACCTID>" <> sgml(account, 22),
        "<ACCTTYPE>CHECKING",
        "</BANKACCTFROM>",
        "<BANKTRANLIST>",
        "<DTSTART>" <> ofx_date(from),
        "<DTEND>" <> ofx_date(to)
      ]
  end

  defp ofx_transaction(%Posting{} = posting) do
    [
      "<STMTTRN>",
      "<TRNTYPE>DEBIT",
      "<DTPOSTED>" <> ofx_date(posting.date),
      "<TRNAMT>" <> Money.format_minor(-posting.amount_cents, 2, separator: "."),
      "<FITID>zipfelkasse-#{posting.expense_id}",
      "<NAME>" <> sgml(posting.payee, 32),
      "<MEMO>" <> sgml(posting.memo, 255),
      "</STMTTRN>"
    ]
  end

  defp ofx_date(date), do: Calendar.strftime(date, "%Y%m%d")

  @doc """
  Text for an SGML field: whitespace collapsed, cut to `max` characters (and the blank at the cut)
  before escaping.
  """
  def sgml(text, max) do
    text = text |> String.split() |> Enum.join(" ")
    codepoints = String.codepoints(text)

    text =
      if length(codepoints) > max,
        do: codepoints |> Enum.take(max) |> Enum.join() |> String.trim(),
        else: text

    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  @doc "A person's postings in YNAB's CSV format."
  def ynab_csv(participant, period, opts \\ []) do
    rows =
      for posting <- postings(participant.id, period, opts) do
        [
          Date.to_iso8601(posting.date),
          cell(posting.payee),
          cell(posting.memo),
          Money.format_minor(posting.amount_cents, 2, separator: "."),
          ""
        ]
      end

    body = csv([~w(Date Payee Memo Outflow Inflow) | rows], ",")
    download("ynab", period, "csv", "text/csv; charset=utf-8", body, opts)
  end

  @doc "A cell a spreadsheet does not take for a formula: =, +, -, @, tab or CR first get a quote."
  def cell(<<first, _rest::binary>> = text) when first in ~c"=+-@\t\r", do: "'" <> text
  def cell(text), do: text

  defp csv(rows, separator) do
    Enum.map_join(rows, fn row ->
      Enum.map_join(row, separator, &csv_field(&1, separator)) <> "\n"
    end)
  end

  defp csv_field(field, separator) do
    if String.contains?(field, [separator, "\"", "\n", "\r"]),
      do: "\"" <> String.replace(field, "\"", "\"\"") <> "\"",
      else: field
  end

  defp expenses(period, participant_id \\ nil) do
    [from: period.from, to: period.to, participant_id: participant_id]
    |> Expenses.list_expenses(sort: :date_asc)
  end

  defp postings(participant_id, period, opts),
    do: Ynab.postings(participant_id, expenses(period, participant_id), now: now(opts))

  defp download(kind, period, extension, content_type, body, opts) do
    today = Keyword.get_lazy(opts, :today, fn -> LocalTime.date(now(opts)) end)

    %{
      filename: "zipfelkasse-#{kind}-#{suffix(period, today)}.#{extension}",
      content_type: content_type,
      body: body
    }
  end

  defp suffix(%{from: nil, to: nil}, today), do: Date.to_iso8601(today)
  defp suffix(%{from: from, to: nil}, _today), do: "ab-" <> Date.to_iso8601(from)
  defp suffix(%{from: nil, to: to}, _today), do: "bis-" <> Date.to_iso8601(to)

  defp suffix(%{from: from, to: to}, _today),
    do: Date.to_iso8601(from) <> "_" <> Date.to_iso8601(to)

  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

  defp timestamp(moment), do: moment |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
