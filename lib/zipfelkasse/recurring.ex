defmodule Zipfelkasse.Recurring do
  @moduledoc """
  Recurring expenses: rules that repeat an expense weekly, monthly or yearly. A rule is made
  from an expense, which becomes its template and first occurrence.

  The occurrences up to today are created by a catch-up, every hour (see
  `Zipfelkasse.Recurring.Job`) and right after a rule is created or resumed: automatically (no
  actor), at most 400 per rule and run. An occurrence is skipped when a live expense on its date
  has the same title regardless of case, payer and amount (of a foreign one the original amount
  and currency). A foreign occurrence takes the rate of its date; without one for good it keeps
  the template's, while ECB rates that could not be loaded leave it for the next run.

  Options of the functions: `:today` and those of `Zipfelkasse.Fx.rate/3`.
  """

  import Ecto.Query

  require Logger

  alias Ecto.Changeset
  alias Zipfelkasse.{Activities, Dates, Expenses, Fx, LocalTime, Money, Names, Repo}
  alias Zipfelkasse.Expenses.Expense
  alias Zipfelkasse.Recurring.RecurringExpense
  alias Zipfelkasse.Recurring.RecurringExpense.Template

  @frequencies [:weekly, :monthly, :yearly]
  @max_per_run 400
  @max_missed 1000
  @max_cents Money.max_cents()

  @doc "The frequencies of a rule."
  def frequencies, do: @frequencies

  @doc "How many occurrences of a rule one catch-up creates at most."
  def max_per_run, do: @max_per_run

  @doc "Up to where `previews/2` counts missed occurrences (it stops at one more)."
  def max_missed, do: @max_missed

  @doc ~s(The frequency as the activity log writes it: `"monatlich"`.)
  def adverb(:weekly), do: "wöchentlich"
  def adverb(:monthly), do: "monatlich"
  def adverb(:yearly), do: "jährlich"

  @doc ~s(The frequency as a label: `"Monatlich"`.)
  def frequency_label(frequency), do: frequency |> adverb() |> String.capitalize()

  @doc "All rules, the active ones first, by next date."
  def list_rules do
    Repo.all(from r in RecurringExpense, order_by: [desc: r.active, asc: r.next_date, asc: r.id])
  end

  @doc "The rule with `id`, or nil."
  def get_rule(id), do: Repo.get(RecurringExpense, id)

  @doc "The rule with `id`; raises if there is none."
  def get_rule!(id), do: Repo.get!(RecurringExpense, id)

  @doc """
  Makes a live expense the template and first occurrence of a rule, which starts on its date,
  and catches up the occurrences since then. Gives the rule and the number of expenses created;
  `{:error, :not_found}` for a deleted expense, `{:error, :already_recurring}` for one of a rule.
  """
  def create_rule(actor_id, %Expense{id: expense_id}, frequency, opts \\ [])
      when frequency in @frequencies do
    Repo.transact(fn ->
      with {:ok, expense} <- fetch_live_expense(expense_id),
           {:ok, rule} <-
             Repo.insert(%RecurringExpense{
               template: template(expense),
               frequency: frequency,
               start_date: expense.date,
               next_date: Dates.next_occurrence(frequency, expense.date, expense.date),
               created_by_id: actor_id
             }),
           {1, _} <-
             Repo.update_all(where(Expense, id: ^expense.id),
               set: [recurring_expense_id: rule.id]
             ),
           {:ok, _activity} <-
             Activities.log(actor_id, :recurring_created, expense.id, %{
               title: expense.title,
               amount_cents: expense.amount_cents,
               text: "„#{expense.title}“ wiederholt sich jetzt #{adverb(frequency)}."
             }) do
        {:ok, rule}
      end
    end)
    |> caught_up(opts)
  end

  defp fetch_live_expense(id) do
    case Repo.get(Expense, id) do
      %Expense{deleted_at: nil, recurring_expense_id: nil} = expense ->
        {:ok, Repo.preload(expense, :shares)}

      %Expense{deleted_at: nil} ->
        {:error, :already_recurring}

      _deleted ->
        {:error, :not_found}
    end
  end

  defp template(expense) do
    %Template{}
    |> RecurringExpense.template_changeset(template_input(expense))
    |> Changeset.apply_changes()
  end

  defp template_input(%Expense{} = expense), do: Map.delete(Expenses.input(expense), :date)

  @doc "Pauses a rule; it keeps its next date."
  def pause_rule(actor_id, %RecurringExpense{id: id}, opts \\ []),
    do: set_active(actor_id, id, false, opts)

  @doc """
  Resumes a rule. The occurrences missed meanwhile are skipped: the next one is the first from
  today on. Then it catches up like `create_rule/4` and gives the number created.
  """
  def resume_rule(actor_id, %RecurringExpense{id: id}, opts \\ []) do
    actor_id |> set_active(id, true, opts) |> caught_up(opts)
  end

  defp set_active(actor_id, id, active, opts) do
    today = today(opts)

    Repo.transact(fn ->
      with {:ok, rule} <- fetch_rule(id),
           {:ok, updated} <-
             rule
             |> Changeset.change(active: active, next_date: next_date(rule, active, today))
             |> Repo.update(force: true),
           {:ok, _activity} <-
             Activities.log_settings(actor_id, "#{label(rule)} #{verb(active)}") do
        {:ok, updated}
      end
    end)
  end

  defp verb(true), do: "fortgesetzt"
  defp verb(false), do: "pausiert"

  defp next_date(%RecurringExpense{active: false} = rule, true, today) do
    if Date.before?(rule.next_date, today),
      do: Dates.next_occurrence(rule.frequency, rule.start_date, Date.add(today, -1)),
      else: rule.next_date
  end

  defp next_date(rule, _active, _today), do: rule.next_date

  # The rule itself was changed, so a failed catch-up is only logged.
  defp caught_up({:ok, rule}, opts) do
    case catch_up_rule(rule.id, opts) do
      {:ok, created} ->
        {:ok, rule, created}

      {:error, created, reason} ->
        Logger.error("Recurring expenses: #{reason}")
        {:ok, rule, created}
    end
  end

  defp caught_up(error, _opts), do: error

  @doc """
  Takes the template from the newest live occurrence; `{:error, :no_occurrence}` without one.
  """
  def refresh_template(actor_id, %RecurringExpense{id: id}) do
    Repo.transact(fn ->
      with {:ok, rule} <- fetch_rule(id),
           {:ok, latest} <- latest_occurrence(id),
           {:ok, updated} <-
             rule
             |> Changeset.cast(%{template: template_input(latest)}, [])
             |> Changeset.cast_embed(:template, with: &RecurringExpense.template_changeset/2)
             |> Repo.update(force: true),
           {:ok, _activity} <-
             Activities.log_settings(
               actor_id,
               "#{label(rule)}: Vorlage aus der letzten Ausgabe übernommen"
             ) do
        {:ok, updated}
      end
    end)
  end

  defp latest_occurrence(id) do
    case Repo.one(
           from e in Expense,
             where: e.recurring_expense_id == ^id and is_nil(e.deleted_at),
             order_by: [desc: e.date, desc: e.id],
             limit: 1,
             preload: :shares
         ) do
      nil -> {:error, :no_occurrence}
      expense -> {:ok, expense}
    end
  end

  @doc "Deletes a rule; its expenses stay, no longer linked to it."
  def delete_rule(actor_id, %RecurringExpense{id: id}) do
    Repo.transact(fn ->
      with {:ok, rule} <- fetch_rule(id),
           {:ok, deleted} <- Repo.delete(rule),
           {:ok, _activity} <-
             Activities.log(actor_id, :recurring_deleted, nil, %{
               title: rule.template.title,
               amount_cents: rule.template.amount_cents,
               text: "Wiederholung von „#{rule.template.title}“ beendet."
             }) do
        {:ok, deleted}
      end
    end)
  end

  defp fetch_rule(id) do
    case get_rule(id) do
      nil -> {:error, :not_found}
      rule -> {:ok, rule}
    end
  end

  defp label(rule), do: "Wiederholung „#{rule.template.title}“ (#{adverb(rule.frequency)})"

  @doc """
  What making `expense` a rule would create, per frequency: the next date after the expense,
  the number of occurrences missed up to today (counting stops after `max_missed/0`) and how
  many of them would be skipped as already entered.
  """
  def previews(%Expense{} = expense, opts \\ []) do
    today = today(opts)

    existing =
      if Date.before?(expense.date, today),
        do: dates_like(expense, Date.add(expense.date, 1), today),
        else: MapSet.new()

    for frequency <- @frequencies do
      next_date = Dates.next_occurrence(frequency, expense.date, expense.date)
      {missed, skipped} = count_missed(frequency, expense.date, next_date, today, existing, 0, 0)
      %{frequency: frequency, next_date: next_date, missed: missed, existing: skipped}
    end
  end

  defp count_missed(frequency, anchor, date, today, existing, missed, skipped) do
    if Date.after?(date, today) or missed > @max_missed do
      {missed, skipped}
    else
      skipped = if MapSet.member?(existing, date), do: skipped + 1, else: skipped
      next = Dates.next_occurrence(frequency, anchor, date)
      count_missed(frequency, anchor, next, today, existing, missed + 1, skipped)
    end
  end

  @doc """
  Catches up all due rules. Gives the number of expenses created, with the errors of the rules
  that failed; the other rules go on.
  """
  @spec catch_up(keyword()) ::
          {:ok, non_neg_integer()} | {:error, non_neg_integer(), [String.t()]}
  def catch_up(opts \\ []) do
    today = today(opts)

    due =
      Repo.all(
        from r in RecurringExpense,
          where: r.active and r.next_date <= ^today,
          order_by: [r.next_date, r.id]
      )

    {created, errors} =
      Enum.reduce(due, {0, []}, fn rule, {created, errors} ->
        case run(rule, today, opts) do
          {count, nil} -> {created + count, errors}
          {count, reason} -> {created + count, [failure(rule, reason) | errors]}
        end
      end)

    if errors == [], do: {:ok, created}, else: {:error, created, Enum.reverse(errors)}
  end

  @doc "Catches up the rule with `id` if it is active and due; as `catch_up/1`."
  @spec catch_up_rule(integer(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, non_neg_integer(), String.t()}
  def catch_up_rule(id, opts \\ []) do
    today = today(opts)

    with %RecurringExpense{active: true} = rule <- get_rule(id),
         false <- Date.after?(rule.next_date, today) do
      case run(rule, today, opts) do
        {count, nil} -> {:ok, count}
        {count, reason} -> {:error, count, failure(rule, reason)}
      end
    else
      _not_due -> {:ok, 0}
    end
  end

  defp failure(rule, reason),
    do: "recurring expense #{rule.id} (#{inspect(rule.template.title)}): #{reason}"

  # Works on a snapshot of the rule: a pause, resume or deletion meanwhile wins.
  defp run(rule, today, opts) do
    existing = dates_like(rule.template, rule.next_date, today)
    step(rule, rule.next_date, today, existing, {0, 0}, opts)
  end

  defp step(rule, date, today, existing, {done, created}, opts) do
    cond do
      Date.after?(date, today) ->
        {created, nil}

      done == @max_per_run ->
        Logger.info(
          "Recurring expense #{rule.id}: per-run limit of #{@max_per_run} reached at #{date}, " <>
            "the rest follows in the next run"
        )

        {created, nil}

      true ->
        case occurrence(rule, date, MapSet.member?(existing, date), opts) do
          {:ok, count} -> advance(rule, date, today, existing, {done + 1, created + count}, opts)
          :changed -> stopped(rule, created)
          {:error, reason} -> {created, reason}
        end
    end
  end

  defp advance(rule, date, today, existing, counts, opts) do
    next = Dates.next_occurrence(rule.frequency, rule.start_date, date)

    case Repo.update_all(
           from(r in RecurringExpense,
             where: r.id == ^rule.id and r.active and r.next_date == ^date
           ),
           set: [next_date: next, updated_at: DateTime.utc_now()]
         ) do
      {1, _} -> step(rule, next, today, existing, counts, opts)
      {0, _} -> stopped(rule, elem(counts, 1))
    end
  end

  defp stopped(rule, created) do
    Logger.info("Recurring expense #{rule.id} changed meanwhile, stopping its catch-up")
    {created, nil}
  end

  defp occurrence(rule, date, true = _exists, _opts) do
    Logger.info(
      "Recurring expense #{rule.id}: an equal expense exists on #{date}, skipping the occurrence"
    )

    {:ok, 0}
  end

  defp occurrence(rule, date, false, opts) do
    with {:ok, attrs} <- instance(rule, date, opts) do
      case Expenses.create_expense(nil, attrs, recurring_expense_id: rule.id) do
        {:ok, _expense} -> {:ok, 1}
        {:error, :rule_changed} -> :changed
        {:error, %Changeset{} = changeset} -> created_before(changeset)
      end
    end
  end

  # After a crash before the next date advanced, the occurrence already exists.
  defp created_before(changeset) do
    case changeset.errors[:recurring_expense_id] do
      {_message, details} when is_list(details) ->
        if details[:constraint] == :unique, do: {:ok, 0}, else: {:error, describe(changeset)}

      nil ->
        {:error, describe(changeset)}
    end
  end

  defp describe(changeset) do
    Enum.map_join(changeset.errors, "; ", fn {field, {message, _details}} ->
      "#{field}: #{message}"
    end)
  end

  defp instance(rule, date, opts) do
    attrs =
      rule.template
      |> Map.take(RecurringExpense.template_fields())
      |> Map.merge(%{
        date: date,
        parts:
          Enum.map(rule.template.parts, &%{participant_id: &1.participant_id, weight: &1.weight})
      })

    if Money.eur?(attrs.original_currency), do: {:ok, attrs}, else: convert(rule, attrs, opts)
  end

  defp convert(rule, %{original_currency: currency, date: date} = attrs, opts) do
    case Fx.rate(currency, date, opts) do
      {:ok, rate} ->
        case Money.to_eur_cents(attrs.original_amount, currency, rate.rate) do
          {:ok, cents} when cents > 0 and cents <= @max_cents ->
            {:ok, %{attrs | fx_rate: rate.rate, fx_source: rate.source}}

          _invalid ->
            {:ok, attrs}
        end

      {:error, :no_rate} ->
        Logger.warning(
          "Recurring expense #{rule.id}: no rate for #{currency} on #{date}, " <>
            "keeping the template's rate"
        )

        {:ok, attrs}

      {:error, {:unavailable, message}} ->
        {:error,
         "rate for #{currency} on #{date} not available, retrying in the next run: #{message}"}
    end
  end

  defp dates_like(%{paid_by_id: nil}, _from, _to), do: MapSet.new()

  defp dates_like(expense, from, to) do
    query =
      from e in Expense,
        where:
          is_nil(e.deleted_at) and e.date >= ^from and e.date <= ^to and
            e.paid_by_id == ^expense.paid_by_id and
            e.title_folded == ^:string.casefold(Names.normalize(expense.title)),
        distinct: true,
        select: e.date

    query =
      if Money.eur?(expense.original_currency) do
        where(
          query,
          [e],
          e.original_currency == "EUR" and e.amount_cents == ^expense.amount_cents
        )
      else
        where(
          query,
          [e],
          e.original_currency == ^expense.original_currency and
            e.original_amount == ^expense.original_amount
        )
      end

    query |> Repo.all() |> MapSet.new()
  end

  defp today(opts), do: Keyword.get_lazy(opts, :today, &LocalTime.today/0)
end
