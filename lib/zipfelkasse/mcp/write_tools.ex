defmodule Zipfelkasse.MCP.WriteTools do
  @moduledoc """
  The tools that add entries, as if the payer had entered them in the app (the payer is the
  author). Amounts are strict: a dot as decimal separator and no thousands separator, so "1.234"
  is never 1234. A likely duplicate is refused unless the call allows it.
  """

  require Logger

  alias Zipfelkasse.{Expenses, Fx, Money, Split}
  alias Zipfelkasse.Expenses.Expense
  alias Zipfelkasse.MCP.{Directory, Output, ReadTools, ToolError}

  @doc "Creates an expense."
  def create_expense(args, opts) do
    title = Directory.given(args.title) || ToolError.raise!("Parameter title is missing.")
    mode = args.split || :equal
    date = ReadTools.date!("date", args.date) || ReadTools.today(opts)
    money = money(args, date, opts)
    directory = Directory.load()
    payer = Directory.active(directory, "paid_by", args.paid_by)

    category =
      if name = Directory.given(args.category) do
        category = Directory.category(name)
        if category.archived_at, do: ToolError.raise!("Category #{category.name} is archived.")
        category
      end

    input =
      Map.merge(money, %{
        title: title,
        notes: args.notes || "",
        date: date,
        paid_by_id: payer.id,
        category_id: category && category.id,
        split_mode: mode,
        parts: parts(directory, mode, money.original_currency, args.participants, args.weights)
      })

    create(input, payer, directory, args.allow_duplicate)
  end

  @doc "Records a settlement payment from one person to another."
  def create_reimbursement(args, opts) do
    date = ReadTools.date!("date", args.date) || ReadTools.today(opts)
    money = money(args, date, opts)
    directory = Directory.load()
    from = Directory.active(directory, "from", args.from)
    to = Directory.active(directory, "to", args.to)

    input =
      Map.merge(money, %{
        title: Expense.reimbursement_title(),
        notes: args.notes || "",
        date: date,
        paid_by_id: from.id,
        reimbursement: true,
        split_mode: :equal,
        parts: [%{participant_id: to.id, weight: 0}]
      })

    create(input, from, directory, args.allow_duplicate)
  end

  # The rate is looked up before anything is written: looking up may download and store rates.
  defp money(args, date, opts) do
    currency = currency!(args.currency)
    minor = minor!(args.amount, currency)
    {rate, source} = rate!(currency, args.fx_rate, date, opts)

    %{
      amount_cents: if(currency == "EUR", do: minor, else: eur_cents(minor, currency, rate)),
      original_amount: minor,
      original_currency: currency,
      fx_rate: rate,
      fx_source: source
    }
  end

  defp currency!(given) do
    currency = String.upcase(Directory.given(given) || "EUR")

    if Money.valid_currency?(currency),
      do: currency,
      else:
        ToolError.raise!(
          "currency must be a three-letter ISO code such as USD, not #{inspect(given)}."
        )
  end

  defp minor!(given, currency) do
    amount = Directory.given(given) || ToolError.raise!("Parameter amount is missing.")
    decimals = Money.decimals(currency)

    case Money.parse_decimal(amount, decimals) do
      {:ok, minor} ->
        minor

      :error ->
        ToolError.raise!(
          "Invalid amount #{inspect(amount)} for #{currency}: #{decimal_rule(decimals)}."
        )
    end
  end

  defp rate!("EUR", nil, _date, _opts), do: {nil, nil}

  defp rate!("EUR", _rate, _date, _opts),
    do: ToolError.raise!("fx_rate is only for foreign currencies.")

  defp rate!(currency, nil, date, opts), do: ecb_rate(currency, date, opts)
  defp rate!(_currency, rate, _date, _opts), do: {rate, :manual}

  # An unusable rate gives 0 €, which the app then refuses with its own message.
  defp eur_cents(minor, currency, rate) do
    case Money.to_eur_cents(minor, currency, rate) do
      {:ok, cents} -> cents
      {:error, _message} -> 0
    end
  end

  defp ecb_rate(currency, date, opts) do
    case Fx.rate(currency, date, today: ReadTools.today(opts)) do
      {:ok, rate} ->
        {rate.rate, rate.source}

      {:error, reason} ->
        Logger.info("MCP: no rate for #{currency} on #{date}: #{inspect(reason)}")

        ToolError.raise!(
          "There is no exchange rate for #{currency} on #{date}. Ask the user for the rate and pass it as fx_rate."
        )
    end
  end

  defp decimal_rule(decimals),
    do:
      "expected digits with at most #{decimals} decimal places after a dot and no thousands separator"

  defp parts(directory, :equal, _currency, participants, weights) do
    if weights != %{},
      do:
        ToolError.raise!(
          "weights are only for split=shares, percent or amount; use participants for an equal split."
        )

    if participants == [] do
      for person <- directory.people,
          is_nil(person.archived_at),
          do: %{participant_id: person.id, weight: 0}
    else
      participants |> Enum.map(&{&1, 0}) |> add_parts(directory)
    end
  end

  defp parts(directory, mode, currency, participants, weights) do
    key = Atom.to_string(mode)

    if participants != [],
      do:
        ToolError.raise!(
          "With split=#{key}, weights name the participants; leave participants out."
        )

    if weights == %{}, do: ToolError.raise!("split=#{key} needs weights (person name → value).")
    decimals = Split.weight_decimals(mode, currency)

    weights
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {name, value} ->
      case Money.parse_decimal(value, decimals) do
        {:ok, weight} ->
          {name, weight}

        :error ->
          ToolError.raise!(
            "Invalid value #{inspect(value)} for #{name} in weights: #{decimal_rule(decimals)}."
          )
      end
    end)
    |> add_parts(directory)
  end

  defp add_parts(weights, directory) do
    {parts, _seen} =
      Enum.map_reduce(weights, MapSet.new(), fn {name, weight}, seen ->
        person = Directory.active(directory, "the split", name)

        if MapSet.member?(seen, person.id),
          do: ToolError.raise!("#{person.name} appears twice in the split.")

        {%{participant_id: person.id, weight: weight}, MapSet.put(seen, person.id)}
      end)

    parts
  end

  defp create(input, payer, directory, allow_duplicate?) do
    if not allow_duplicate? and input.amount_cents > 0,
      do: refuse_duplicate(Expenses.find_duplicate(input))

    case Expenses.create_expense(payer.id, input, text: "Über MCP angelegt") do
      {:ok, expense} ->
        Logger.info("MCP created entry #{expense.id}")

        [
          created: Output.expense(expense, directory, true),
          note:
            "Created as entry #{expense.id} with #{payer.name} as author. Changing or deleting it is only " <>
              "possible in the app."
        ]

      {:error, %Ecto.Changeset{} = changeset} ->
        ToolError.raise!(
          "The app refused the entry (message in German): #{first_error(changeset)}"
        )
    end
  end

  defp refuse_duplicate(nil), do: :ok

  defp refuse_duplicate(%Expense{} = same) do
    ToolError.raise!(
      "This looks like a duplicate of entry #{same.id} (#{same.date}, #{same.title}, " <>
        "#{Output.eur(same.amount_cents)} EUR, paid by #{same.paid_by.name}). Ask the user; if it really is " <>
        "a second one, call again with allow_duplicate=true."
    )
  end

  # The first error found; Ecto keeps the newest first.
  defp first_error(changeset) do
    {_field, {message, values}} = List.last(changeset.errors)

    Regex.replace(~r/%{(\w+)}/, message, fn whole, key ->
      values |> Keyword.get(String.to_existing_atom(key), whole) |> to_string()
    end)
  end
end
