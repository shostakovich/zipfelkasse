defmodule Zipfelkasse.MCP.ReadTools do
  @moduledoc "The read tools of `Zipfelkasse.MCP.Tools`; each takes the decoded arguments."

  alias Zipfelkasse.{Activities, Balances, Categories, Dates, Expenses, Ledger, LocalTime}
  alias Zipfelkasse.{MCP, Periods, Repo, Schema, Statistics}
  alias Zipfelkasse.MCP.{Directory, Output, SqlSandbox, ToolError, Tools}

  @no_category "No category"
  @balance_note "Positive balance = is owed money, negative = owes money. settlements: the transfers " <>
                  "needed so that everyone ends at 0."
  @schema_text File.read!(Path.join(__DIR__, "texts/schema.txt"))
  @external_resource Path.join(__DIR__, "texts/schema.txt")

  @doc "Balances and the transfers that settle them."
  def balances(_args, _opts) do
    balances = Balances.balances()
    directory = Directory.load()

    entries =
      for person <- directory.people,
          cents = Map.get(balances, person.id, 0),
          is_nil(person.archived_at) or cents != 0,
          do: Output.balance(person.name, cents, status(cents))

    settlements =
      for transfer <- Ledger.settle(balances) do
        [
          from: Directory.name(directory, transfer.from),
          to: Directory.name(directory, transfer.to),
          amount: Output.eur(transfer.amount_cents),
          amount_cents: transfer.amount_cents
        ]
      end

    [balances: entries, settlements: settlements, note: @balance_note]
  end

  defp status(cents) when cents > 0, do: "is owed money"
  defp status(cents) when cents < 0, do: "owes money"
  defp status(_cents), do: "settled"

  @doc "The balances at the end of each period."
  def balance_history(args, opts) do
    unit = args.interval || :month
    {from, to} = range!(args.from, args.to)
    directory = Directory.load()
    person = Directory.find(directory, args.person)
    today = today(opts)
    if from, do: check_periods!(length(Periods.labels(unit, from, earlier(to, today))))

    history = Balances.history(unit, from: from, to: to, today: today)
    check_periods!(length(history.periods))

    {rows, _ever} =
      Enum.map_reduce(history.periods, MapSet.new(), fn {label, balances}, ever ->
        ever =
          for {id, cents} <- balances, cents != 0, into: ever, do: id

        balances =
          for p <- directory.people,
              shown?(p, person, ever),
              do: Output.balance(p.name, Map.get(balances, p.id, 0))

        {[{unit, label}, balances: balances], ever}
      end)

    [
      interval: Atom.to_string(unit),
      period: Output.range(history.from, history.to),
      rows: rows,
      note:
        "Balance after all expenses dated up to the end of each period (in the current period also those " <>
          "dated later this period), positive = is owed money, negative = owes money. Without to, the last " <>
          "row equals the current balances. Computed from the current data by expense date: later edits and " <>
          "deletions apply retroactively."
    ]
  end

  # Archived people show up once they had a balance, or when asked for.
  defp shown?(p, nil, ever), do: is_nil(p.archived_at) or MapSet.member?(ever, p.id)
  defp shown?(p, person, _ever), do: p.id == person.id

  defp check_periods!(count) do
    if count > Tools.max_rows(),
      do:
        ToolError.raise!(
          "That is #{count} periods, at most #{Tools.max_rows()} are possible. Please narrow down " <>
            "from/to or choose a longer interval."
        )
  end

  @doc "Individual expenses by filters, with their total."
  def search_expenses(args, _opts) do
    {from, to} = range!(args.from, args.to)
    {category_id, without_category} = category_arg(args.category)
    directory = Directory.load()
    person = Directory.find(directory, args.person)
    payer = Directory.find(directory, args.paid_by)
    involved = Directory.find(directory, args.involved)
    {min_cents, max_cents} = bounds!(args)
    limit = limit!(args.limit, 50)

    matches =
      Expenses.list_expenses(
        [
          text: args.text,
          from: from,
          to: to,
          category_id: category_id,
          without_category: without_category,
          participant_id: id(person),
          paid_by_id: id(payer),
          involved_id: id(involved),
          min_cents: min_cents,
          max_cents: max_cents,
          reimbursement: reimbursement_filter(args.reimbursements || :exclude)
        ],
        sort: args.sort || :date_desc
      )

    shown = Enum.take(matches, limit)
    total = matches |> Enum.map(& &1.amount_cents) |> Enum.sum()

    Output.compact(
      matches: length(matches),
      shown: length(shown),
      truncated: length(matches) > length(shown),
      total: Output.eur(total),
      total_cents: total,
      expenses: Enum.map(shown, &Output.expense(&1, directory, args.detail == :full)),
      person_share: person_share(matches, person || involved)
    )
  end

  defp id(nil), do: nil
  defp id(person), do: person.id

  defp bounds!(args) do
    min_cents = amount_cents!("min_amount", args.min_amount)
    max_cents = amount_cents!("max_amount", args.max_amount)
    if max_cents == 0, do: ToolError.raise!("max_amount must be greater than 0.")

    if min_cents && max_cents && min_cents > max_cents,
      do:
        ToolError.raise!(
          "min_amount (#{Output.eur(min_cents)}) is greater than max_amount (#{Output.eur(max_cents)})."
        )

    {min_cents, max_cents}
  end

  defp person_share(_matches, nil), do: nil

  defp person_share(matches, person) do
    share = matches |> Enum.map(&Expenses.Expense.share_of(&1, person.id)) |> Enum.sum()
    [person: person.name, amount: Output.eur(share), amount_cents: share]
  end

  defp reimbursement_filter(:exclude), do: false
  defp reimbursement_filter(:only), do: true
  defp reimbursement_filter(:include), do: nil

  @doc "Expense totals by a grouping, optionally compared with the year before."
  def statistics(args, opts) do
    group = args.group_by
    {from, to} = range!(args.from, args.to)
    {category_id, without_category} = category_arg(args.category)
    sharer = Directory.find(Directory.load(), args.share_of)
    limit = limit!(args.limit, Tools.max_rows())
    today = today(opts)
    compare? = not is_nil(args.compare)
    time_keyed? = Statistics.time?(group) or group == :category_month
    to = compared_end!(compare? and not time_keyed?, group, from, to, today)

    filter = %{
      group_by: group,
      from: from,
      to: to,
      participant_id: id(sharer),
      category_id: category_id,
      without_category: without_category,
      text: args.text
    }

    found = Statistics.rows(filter)
    rows = if Statistics.time?(group), do: Statistics.fill_gaps(found, filter, today), else: found
    total = rows |> Enum.map(& &1.amount_cents) |> Enum.sum()

    {pairs, previous} =
      if compare?,
        do: compare(filter, found, rows, today, time_keyed?),
        else: {Enum.map(rows, &{&1, nil}), nil}

    previous_total = if compare?, do: pairs |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    Output.compact(
      group_by: Atom.to_string(group),
      perspective: perspective(sharer),
      period: Output.range(from, to),
      rows:
        pairs
        |> Enum.take(limit)
        |> Enum.map(fn {row, before} -> stat_line(row, group, before) end),
      rows_total: length(pairs),
      truncated: length(pairs) > limit,
      total: Output.eur(total),
      total_cents: total,
      previous_period: previous,
      previous_total: previous_total && Output.eur(previous_total),
      previous_total_cents: previous_total,
      note: statistics_note(group, compare?)
    )
  end

  defp statistics_note(group, compare?) do
    "Reimbursements and deleted expenses are not included. count = number of expenses." <>
      if(group == :person,
        do: " amount = the person's share (consumption), paid = what they paid for the group.",
        else: ""
      ) <>
      if(compare?,
        do:
          " previous = same group one year earlier, change = amount − previous, change_percent relative to " <>
            "previous (missing if previous is 0).",
        else: ""
      )
  end

  defp perspective(nil), do: "total amounts of the expenses"
  defp perspective(person), do: "only the share of #{person.name}"

  defp compared_end!(false, _group, _from, to, _today), do: to

  defp compared_end!(true, group, nil, _to, _today),
    do:
      ToolError.raise!(
        "compare=previous_year with group_by=#{group} needs from (and optionally to): the period to compare."
      )

  defp compared_end!(true, _group, from, nil, today) do
    if Date.before?(today, from),
      do:
        ToolError.raise!(
          "from (#{Date.to_iso8601(from)}) is in the future; compare=previous_year needs a period up to " <>
            "today or an explicit to."
        ),
      else: today
  end

  defp compared_end!(true, _group, _from, to, _today), do: to

  defp compare(filter, found, rows, today, time_keyed?) do
    previous_filter = %{
      filter
      | from: filter.from && Date.shift(filter.from, year: -1),
        to: filter.to && Date.shift(filter.to, year: -1)
    }

    previous_rows =
      if previous_filter.from || previous_filter.to,
        do: Statistics.rows(previous_filter),
        else: found

    window = if time_keyed?, do: Statistics.period_window(filter, found, today)
    pairs = Statistics.with_previous(rows, previous_rows, window, filter.group_by)

    period =
      if time_keyed?,
        do:
          "each #{String.replace_prefix(Atom.to_string(filter.group_by), "category_", "")} one year earlier",
        else: Output.range(previous_filter.from, previous_filter.to)

    {pairs, period}
  end

  defp stat_line(row, group, previous) do
    category = if group in [:category, :category_month], do: row.category || @no_category

    line = [
      category: category,
      title: row.title,
      year: if(group == :year, do: row.period),
      month: if(group in [:month, :category_month], do: row.period),
      week: if(group == :week, do: row.period),
      person: row.person,
      count: row.count,
      amount: Output.eur(row.amount_cents),
      amount_cents: row.amount_cents,
      paid: if(group == :person and row.paid_cents, do: Output.eur(row.paid_cents)),
      paid_cents: if(group == :person, do: row.paid_cents)
    ]

    Output.compact(line ++ change(row.amount_cents, previous))
  end

  defp change(_cents, nil), do: []

  defp change(cents, previous) do
    change = cents - previous

    [
      previous: Output.eur(previous),
      previous_cents: previous,
      change: Output.eur(change),
      change_cents: change,
      change_percent: if(previous != 0, do: round(change * 1000 / previous) / 10)
    ]
  end

  @doc "The activity log by filters, newest first, in pages."
  def activity(args, _opts) do
    {from, to} = range!(args.from, args.to)
    since = from && local_midnight(from)
    until = to && local_midnight(Date.add(to, 1))
    actor = Directory.find(Directory.load(), args.person)

    if Enum.any?([args.expense_id, args.before_id], &(&1 && &1 < 1)),
      do: ToolError.raise!("expense_id and before_id must be positive.")

    limit = limit!(args.limit, 50)

    entries =
      Activities.list_activities(
        expense_id: args.expense_id,
        actor_id: actor && actor.id,
        action: args.action,
        since: since,
        until: until,
        before_id: args.before_id,
        limit: limit + 1
      )

    more? = length(entries) > limit
    entries = Enum.take(entries, limit)

    Output.compact(
      entries: Enum.map(entries, &entry/1),
      shown: length(entries),
      more: more?,
      note:
        if(more?,
          do: "There are older entries: call again with before_id=#{List.last(entries).id}."
        )
    )
  end

  defp local_midnight(date) do
    date |> NaiveDateTime.new!(~T[00:00:00]) |> LocalTime.to_utc() |> Schema.usec()
  end

  defp entry(activity) do
    details = activity.details

    Output.compact(
      id: activity.id,
      at: Output.local_time(activity.inserted_at),
      actor: if(activity.actor, do: activity.actor.name, else: "system"),
      action: Atom.to_string(activity.action),
      expense_id: activity.expense_id,
      title: details.title,
      amount: details.amount_cents && Output.eur(details.amount_cents),
      amount_cents: details.amount_cents,
      changes:
        if(details.changes != [],
          do: Enum.map(details.changes, &[field: &1.field, old: &1.old, new: &1.new])
        ),
      text: details.text
    )
  end

  @doc "The database explained, with people, categories and the CREATE statements."
  def schema(_args, opts) do
    directory = Directory.load()

    people =
      Enum.map_join(directory.people, ", ", fn p ->
        "#{p.id}: #{p.name}" <> if(p.archived_at, do: " (archived)", else: "")
      end)

    categories =
      Enum.map_join(Categories.list_categories(:all), ", ", fn c ->
        "#{c.id}: #{c.name}" <> if(c.archived_at, do: " (archived)", else: "")
      end)

    statements = Enum.map_join(SqlSandbox.schema(Repo), &(&1 <> ";\n"))

    MCP.today_line(opts) <>
      "\n\n" <>
      @schema_text <>
      "\nPeople (id: name): " <>
      people <>
      "\nCategories (id: name): " <> categories <> "\n\nCREATE statements:\n" <> statements
  end

  @doc "A read-only SQL query on a copy of the data."
  def sql_query(args, _opts) do
    query = args.query

    if is_nil(query) or String.trim(query) == "",
      do: ToolError.raise!("Parameter query is missing.")

    case SqlSandbox.query(Repo.config()[:database], query) do
      {:ok, result} ->
        Output.compact(
          columns: result.columns,
          rows: result.rows,
          row_count: length(result.rows),
          truncated: result.truncated,
          note: result.note
        )

      {:error, message} ->
        ToolError.raise!(message)
    end
  end

  @doc "A date argument, nil if not given; refuses an invalid one."
  def date!(name, value) do
    if value = Directory.given(value) do
      case Dates.parse(value) do
        {:ok, date} ->
          date

        {:error, _message} ->
          ToolError.raise!("Invalid date for #{name}: #{inspect(value)} (expected YYYY-MM-DD).")
      end
    end
  end

  defp range!(from, to) do
    from = date!("from", from)
    to = date!("to", to)

    if from && to && Date.before?(to, from),
      do: ToolError.raise!(~s|"to" (#{to}) is before "from" (#{from}).|),
      else: {from, to}
  end

  # "none" and "No category" select expenses without a category, unless a category has that name.
  defp category_arg(name) do
    if name = Directory.given(name) do
      try do
        {Directory.category(name).id, false}
      rescue
        refusal in ToolError ->
          if String.downcase(name) in ["none", String.downcase(@no_category)],
            do: {nil, true},
            else: reraise(refusal, __STACKTRACE__)
      end
    else
      {nil, false}
    end
  end

  defp amount_cents!(_name, nil), do: nil

  defp amount_cents!(name, euros) do
    if euros < 0 or euros > 1.0e12,
      do: ToolError.raise!("#{name} must be an amount in euros of at least 0."),
      else: round(euros * 100)
  end

  defp limit!(nil, default), do: default

  defp limit!(limit, _default) do
    if limit in 1..Tools.max_rows()//1,
      do: limit,
      else: ToolError.raise!("limit must be between 1 and #{Tools.max_rows()}.")
  end

  @doc "The local date of the call."
  def today(opts), do: Keyword.get_lazy(opts, :today, &LocalTime.today/0)

  defp earlier(nil, today), do: today
  defp earlier(date, today), do: Enum.min([date, today], Date)
end
