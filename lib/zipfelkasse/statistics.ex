defmodule Zipfelkasse.Statistics do
  @moduledoc """
  Expense totals by category, title (case-folded, so by merchant), year, month, ISO week, person
  or category and month. Reimbursements and deleted expenses never count.

  A filter is a map with `:group_by` and optionally `:from`, `:to` (dates, inclusive),
  `:participant_id` (only that person's shares count), `:category_id`, `:without_category` and
  `:text` (terms in the title or notes, any of which matches). Grouped by person, `amount_cents`
  is the person's share and `paid_cents` what they paid.
  """

  alias Zipfelkasse.{Expenses, Periods, Repo}

  @groups [:category, :title, :year, :month, :week, :person, :category_month]
  @no_category "No category"

  @type group :: :category | :title | :year | :month | :week | :person | :category_month
  @type row :: %{
          category: String.t() | nil,
          title: String.t() | nil,
          period: String.t() | nil,
          person: String.t() | nil,
          count: non_neg_integer(),
          amount_cents: integer(),
          paid_cents: integer() | nil
        }

  @doc "The groupings."
  def groups, do: @groups

  @doc "The period unit of a grouping, or nil."
  def unit(:year), do: :year
  def unit(group) when group in [:month, :category_month], do: :month
  def unit(:week), do: :week
  def unit(_group), do: nil

  @doc "Whether a grouping is by time only."
  def time?(group), do: group in [:year, :month, :week]

  defp row(fields) do
    Map.merge(
      %{
        category: nil,
        title: nil,
        period: nil,
        person: nil,
        count: 0,
        amount_cents: 0,
        paid_cents: nil
      },
      Map.new(fields)
    )
  end

  @doc """
  The rows of a filter: by amount for categories and titles, by period for time groupings, by
  share for people.
  """
  @spec rows(map()) :: [row()]
  def rows(%{group_by: :person} = filter) do
    {conditions, args} = conditions(filter)

    sql = """
    SELECT p.name,
      (SELECT count(*) FROM expense_shares x JOIN expenses e ON e.id = x.expense_id
        WHERE x.participant_id = p.id AND #{conditions}),
      (SELECT coalesce(sum(x.amount_cents), 0) FROM expense_shares x JOIN expenses e ON e.id = x.expense_id
        WHERE x.participant_id = p.id AND #{conditions}),
      (SELECT coalesce(sum(e.amount_cents), 0) FROM expenses e WHERE e.paid_by_id = p.id AND #{conditions})
    FROM participants p
    """

    {sql, args} =
      if filter[:participant_id],
        do: {sql <> " WHERE p.id = ?", args ++ args ++ args ++ [filter.participant_id]},
        else: {sql, args ++ args ++ args}

    Repo.query!(sql, args).rows
    |> Enum.reject(fn [_name, count, _cents, paid] -> count == 0 and paid == 0 end)
    |> Enum.sort_by(fn [name, _count, cents, _paid] -> {-cents, String.downcase(name)} end)
    |> Enum.map(fn [name, count, cents, paid] ->
      row(person: name, count: count, amount_cents: cents, paid_cents: paid)
    end)
  end

  def rows(%{group_by: group} = filter) do
    {conditions, args} = conditions(filter)
    period = period_sql(group)

    {joins, amount, args} =
      if filter[:participant_id],
        do:
          {" JOIN expense_shares x ON x.expense_id = e.id AND x.participant_id = ?",
           "x.amount_cents", [filter.participant_id | args]},
        else: {"", "e.amount_cents", args}

    {label, grouping, order} =
      case group do
        :category -> {"c.name", "c.name", "4 DESC, c.name IS NULL, c.name"}
        :title -> {"max(e.title)", "e.title_folded", "4 DESC, 1"}
        :category_month -> {"c.name", "c.name, #{period}", "2, 4 DESC, c.name IS NULL, c.name"}
        _time -> {"NULL", period, "2"}
      end

    sql =
      "SELECT #{label}, #{period}, count(*), sum(#{amount}) " <>
        "FROM expenses e LEFT JOIN categories c ON c.id = e.category_id#{joins} " <>
        "WHERE #{conditions} GROUP BY #{grouping} ORDER BY #{order}"

    for [name, period, count, cents] <- Repo.query!(sql, args).rows do
      if group == :title,
        do: row(title: name, period: period, count: count, amount_cents: cents),
        else: row(category: name, period: period, count: count, amount_cents: cents)
    end
  end

  # The ISO week year and week; SQLite before 3.46 knows neither.
  defp period_sql(:year), do: "substr(e.date, 1, 4)"
  defp period_sql(group) when group in [:month, :category_month], do: "substr(e.date, 1, 7)"
  defp period_sql(:week), do: "strftime('%G-W%V', e.date)"
  defp period_sql(_group), do: "NULL"

  # The search of the expense list, so that both find the same expenses.
  defp conditions(filter) do
    {ids, args} =
      Expenses.filter_sql(
        from: filter[:from],
        to: filter[:to],
        text: filter[:text],
        without_category: filter[:without_category] == true,
        category_id: category_id(filter)
      )

    {"e.reimbursement = 0 AND e.id IN (#{ids})", args}
  end

  defp category_id(%{without_category: true}), do: nil
  defp category_id(%{category_id: id}) when is_integer(id), do: id
  defp category_id(_filter), do: nil

  @doc """
  Time rows gap-filled with 0 from the first period (of `:from`, or of the first row) to the
  one of `:to`, never beyond today. Rows outside stay.
  """
  def fill_gaps(rows, %{group_by: group} = filter, today) do
    unit = unit(group)
    first = filter[:from] || (rows != [] && Periods.first_day(unit, hd(rows).period)) || nil
    last = earlier(filter[:to], today)

    if is_nil(first) or not time?(group) or Date.after?(first, last) do
      rows
    else
      labels = Periods.labels(unit, first, last)
      have = Map.new(rows, &{&1.period, &1})
      inside = MapSet.new(labels)

      labels
      |> Enum.map(&(Map.get(have, &1) || row(period: &1)))
      |> Kernel.++(Enum.reject(rows, &MapSet.member?(inside, &1.period)))
      |> Enum.sort_by(&(&1.period || ""))
    end
  end

  @doc "Whether a period lies between the first one of `:from` (or of the rows) and the last one."
  def period_window(%{group_by: group} = filter, rows, today) do
    unit = unit(group)

    first =
      if filter[:from],
        do: Periods.label(unit, filter.from),
        else: rows |> Enum.map(& &1.period) |> Enum.reject(&is_nil/1) |> Enum.min(fn -> nil end)

    if first do
      last = Periods.label(unit, earlier(filter[:to], today))
      fn period -> first <= period and period <= last end
    else
      fn _period -> false end
    end
  end

  defp earlier(nil, today), do: today
  defp earlier(date, today), do: Enum.min([date, today], Date)

  @doc """
  Pairs each row with the amount of the same group one year earlier, from `previous` (week 53
  counts as week 52 in a year without one). Groups only in `previous` are added with 0; for time
  groupings (with a `window`) only within it, sorted back into place.
  """
  def with_previous(rows, previous, window, group) do
    {earlier, order} = Enum.reduce(previous, {%{}, []}, &add_earlier/2)

    {pairs, earlier} =
      Enum.map_reduce(rows, earlier, fn row, earlier ->
        {before, earlier} = Map.pop(earlier, key(row))
        {{row, if(before, do: before.amount_cents, else: 0)}, earlier}
      end)

    added =
      for key <- Enum.reverse(order),
          gone = earlier[key],
          gone != nil,
          is_nil(window) or window.(gone.period || ""),
          do: {gone_row(gone, group), gone.amount_cents}

    if added != [] and window, do: sort_back(pairs ++ added), else: pairs ++ added
  end

  defp add_earlier(row, {earlier, order}) do
    shifted = %{row | period: row.period && Periods.shift_label(row.period, 1)}
    key = key(shifted)

    case earlier do
      %{^key => have} ->
        {%{earlier | key => %{have | amount_cents: have.amount_cents + shifted.amount_cents}},
         order}

      _new ->
        {Map.put(earlier, key, shifted), [key | order]}
    end
  end

  defp gone_row(gone, group) do
    row(
      category: gone.category,
      title: gone.title,
      period: gone.period,
      person: gone.person,
      paid_cents: if(group == :person, do: 0)
    )
  end

  defp sort_back(pairs) do
    pairs
    |> Enum.with_index()
    |> Enum.sort_by(fn {{row, _previous}, index} ->
      {row.period || "", -row.amount_cents, row.category || @no_category, index}
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp key(row),
    do: {row.category, row.title && :string.casefold(row.title), row.person, row.period}
end
