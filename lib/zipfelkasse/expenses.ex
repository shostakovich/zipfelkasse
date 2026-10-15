defmodule Zipfelkasse.Expenses do
  @moduledoc """
  Expenses and reimbursements with their shares. Each change is written together with its
  activity entry; afterwards `{:expenses_changed, ids}` goes out on the topic `"expenses"`.

  An expense input is a map as `input/1` returns it; `Zipfelkasse.Expenses.Expense.changeset/2`
  checks it.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Phoenix.PubSub
  alias Zipfelkasse.{Activities, Dates, Fx, Money, Participants, Repo, Suggestions}
  alias Zipfelkasse.Activities.Changes
  alias Zipfelkasse.Categories.Category
  alias Zipfelkasse.Expenses.{Expense, ExpenseShare, Form}
  alias Zipfelkasse.Participants.Participant
  alias Zipfelkasse.Recurring.RecurringExpense

  @topic "expenses"
  @preloads [:category, :paid_by, :shares]

  @doc "Subscribes the caller to `{:expenses_changed, ids}`."
  def subscribe, do: PubSub.subscribe(Zipfelkasse.PubSub, @topic)

  defp broadcast(ids), do: PubSub.broadcast(Zipfelkasse.PubSub, @topic, {:expenses_changed, ids})

  @doc "The expense with `id`, deleted ones too, with category, payer and shares; or nil."
  def get_expense(id), do: Expense |> Repo.get(id) |> Repo.preload(@preloads)

  @doc "The expense with `id` as `get_expense/1`; raises if there is none."
  def get_expense!(id), do: Expense |> Repo.get!(id) |> Repo.preload(@preloads)

  @doc """
  The live expenses, newest first (by date, then id), with category, payer and shares.

  Filters: `:q` (in the title or the notes, regardless of case), `:text` (a list of such terms,
  any of which matches), `:from` and `:to` (dates, inclusive), `:category_id`,
  `:without_category`, `:participant_id` (paid or shares), `:paid_by_id`, `:involved_id`
  (shares), `:min_cents`, `:max_cents` and `:reimbursement` (true or false). Options: `:sort`
  (`:date_desc`, `:date_asc`, `:amount_desc`, `:amount_asc`), `:limit` and `:after`, the
  `{date, id}` of the last expense of the page before.
  """
  def list_expenses(filters \\ [], opts \\ []) do
    from(e in Expense, as: :expense, where: is_nil(e.deleted_at))
    |> filter(filters)
    |> after_cursor(opts[:after])
    |> sort(Keyword.get(opts, :sort, :date_desc))
    |> limit_to(opts[:limit])
    |> preload(^@preloads)
    |> Repo.all()
  end

  @doc """
  The ids of the live expenses that `filters` match (as `list_expenses/2`) as SQL with its
  arguments, so that a query of its own filters them the same way: `e.id IN (…)`.
  """
  def filter_sql(filters) do
    from(e in Expense, as: :expense, where: is_nil(e.deleted_at), select: e.id)
    |> filter(filters)
    |> then(&Repo.to_sql(:all, &1))
  end

  defp filter(query, filters), do: Enum.reduce(filters, query, &filter_by/2)

  defp filter_by({_filter, nil}, query), do: query
  defp filter_by({:q, text}, query), do: search(query, [text])
  defp filter_by({:text, terms}, query), do: search(query, terms)
  defp filter_by({:from, date}, query), do: where(query, [e], e.date >= ^date)
  defp filter_by({:to, date}, query), do: where(query, [e], e.date <= ^date)
  defp filter_by({:category_id, id}, query), do: where(query, [e], e.category_id == ^id)
  defp filter_by({:without_category, true}, query), do: where(query, [e], is_nil(e.category_id))
  defp filter_by({:without_category, false}, query), do: query
  defp filter_by({:paid_by_id, id}, query), do: where(query, [e], e.paid_by_id == ^id)
  defp filter_by({:involved_id, id}, query), do: where(query, [e], exists(shares_of(id)))
  defp filter_by({:min_cents, cents}, query), do: where(query, [e], e.amount_cents >= ^cents)
  defp filter_by({:max_cents, cents}, query), do: where(query, [e], e.amount_cents <= ^cents)
  defp filter_by({:reimbursement, flag}, query), do: where(query, [e], e.reimbursement == ^flag)

  defp filter_by({:participant_id, id}, query),
    do: where(query, [e], e.paid_by_id == ^id or exists(shares_of(id)))

  defp search(query, terms) do
    terms
    |> Enum.map(&:string.casefold(String.trim(&1)))
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce(nil, fn term, matches ->
      match =
        dynamic(
          [e],
          fragment("instr(?, ?) > 0", e.title_folded, ^term) or
            fragment("instr(?, ?) > 0", e.notes_folded, ^term)
        )

      if matches, do: dynamic(^matches or ^match), else: match
    end)
    |> case do
      nil -> query
      matches -> where(query, ^matches)
    end
  end

  defp sort(query, :date_desc), do: order_by(query, [e], desc: e.date, desc: e.id)
  defp sort(query, :date_asc), do: order_by(query, [e], asc: e.date, asc: e.id)

  defp sort(query, :amount_desc),
    do: order_by(query, [e], desc: e.amount_cents, desc: e.date, desc: e.id)

  defp sort(query, :amount_asc),
    do: order_by(query, [e], asc: e.amount_cents, desc: e.date, desc: e.id)

  defp shares_of(participant_id) do
    from s in ExpenseShare,
      where: s.expense_id == parent_as(:expense).id and s.participant_id == ^participant_id
  end

  defp limit_to(query, nil), do: query
  defp limit_to(query, count), do: limit(query, ^count)

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {date, id}),
    do: where(query, [e], e.date < ^date or (e.date == ^date and e.id < ^id))

  @doc "The input of an expense (with its shares), as `create_expense/3` takes it."
  def input(%Expense{} = expense) do
    expense
    |> Map.take([:date | RecurringExpense.template_fields()])
    |> Map.put(
      :parts,
      Enum.map(expense.shares, &%{participant_id: &1.participant_id, weight: &1.weight})
    )
  end

  @doc """
  Creates an expense from its input. Options: `:text` for the activity entry and
  `:recurring_expense_id`, the rule it is an occurrence of; `{:error, :rule_changed}` when that
  rule is paused, gone or no longer due on the expense's date.
  """
  def create_expense(actor_id, attrs, opts \\ []) do
    rule_id = opts[:recurring_expense_id]
    changeset = Expense.changeset(%Expense{recurring_expense_id: rule_id}, attrs)

    Repo.transact(fn ->
      with :ok <- due_rule(rule_id, Changeset.get_field(changeset, :date)),
           {:ok, changeset} <- validate_references(changeset, :insert),
           {:ok, expense} <- Repo.insert(changeset),
           {:ok, shares} <- Expense.shares(expense, expense.id),
           :ok <- insert_shares(expense.id, shares),
           {:ok, _activity} <-
             Activities.log(actor_id, :expense_created, expense.id, %{
               title: expense.title,
               amount_cents: expense.amount_cents,
               text: opts[:text]
             }) do
        {:ok, {expense, true}}
      end
    end)
    |> committed()
  end

  defp due_rule(nil, _date), do: :ok

  defp due_rule(id, date) do
    if Repo.exists?(
         from r in RecurringExpense, where: r.id == ^id and r.active and r.next_date == ^date
       ),
       do: :ok,
       else: {:error, :rule_changed}
  end

  @doc """
  Saves a new input for a live expense. Saved unchanged, nothing is written: no time stamp, no
  activity entry, no broadcast. A deleted expense gives `{:error, :deleted}`.
  """
  def update_expense(actor_id, %Expense{id: id}, attrs) do
    Repo.transact(fn ->
      with {:ok, old} <- fetch_live(id),
           {:ok, changeset} <- validate_references(Expense.changeset(old, attrs), :update),
           {:ok, new} <- Changeset.apply_action(changeset, :update),
           {:ok, shares} <- Expense.shares(new, id) do
        changes = Changes.expense(old, %{new | shares: shares}, names(), category_names())
        update(actor_id, old, changeset, shares, changes)
      end
    end)
    |> committed()
  end

  defp update(_actor_id, old, _changeset, _shares, []), do: {:ok, {old, false}}

  defp update(actor_id, _old, changeset, shares, changes) do
    with {:ok, expense} <- Repo.update(changeset, force: true),
         {_deleted, _} <- Repo.delete_all(where(ExpenseShare, expense_id: ^expense.id)),
         :ok <- insert_shares(expense.id, shares),
         {:ok, _activity} <-
           Activities.log(actor_id, :expense_updated, expense.id, %{
             title: expense.title,
             amount_cents: expense.amount_cents,
             changes: changes
           }) do
      {:ok, {expense, true}}
    end
  end

  @doc "Deletes a live expense softly; it stays readable but out of lists and balances."
  def delete_expense(actor_id, %Expense{id: id}) do
    Repo.transact(fn ->
      with {:ok, old} <- fetch_live(id),
           {:ok, expense} <-
             old |> Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update(),
           {:ok, _activity} <-
             Activities.log(actor_id, :expense_deleted, id, %{
               title: old.title,
               amount_cents: old.amount_cents
             }) do
        {:ok, {expense, true}}
      end
    end)
    |> case do
      {:error, :deleted} -> {:error, :not_found}
      result -> committed(result)
    end
  end

  defp fetch_live(id) do
    case get_expense(id) do
      nil -> {:error, :not_found}
      %Expense{deleted_at: nil} = expense -> {:ok, expense}
      %Expense{} -> {:error, :deleted}
    end
  end

  defp committed({:ok, {expense, changed?}}) do
    if changed?, do: broadcast([expense.id])
    {:ok, get_expense!(expense.id)}
  end

  defp committed({:error, _reason} = error), do: error

  # Archived people and categories are fine: old expenses keep them.
  defp validate_references(%Changeset{valid?: false} = changeset, action),
    do: {:error, %{changeset | action: action}}

  defp validate_references(changeset, action) do
    payer = Changeset.get_field(changeset, :paid_by_id)

    ids =
      Enum.uniq([payer | Enum.map(Changeset.get_field(changeset, :parts), & &1.participant_id)])

    known = Repo.all(from p in Participant, where: p.id in ^ids, select: p.id)
    category_id = Changeset.get_field(changeset, :category_id)

    changeset =
      cond do
        payer not in known ->
          Changeset.add_error(changeset, :paid_by_id, "Unbekannte Person in der Ausgabe.")

        length(known) < length(ids) ->
          Changeset.add_error(changeset, :parts, "Unbekannte Person in der Ausgabe.")

        true ->
          changeset
      end

    changeset =
      if category_id && not Repo.exists?(where(Category, id: ^category_id)),
        do: Changeset.add_error(changeset, :category_id, "Unbekannte Kategorie."),
        else: changeset

    if changeset.valid?, do: {:ok, changeset}, else: {:error, %{changeset | action: action}}
  end

  defp insert_shares(expense_id, shares) do
    Repo.insert_all(ExpenseShare, Enum.map(shares, &Map.put(&1, :expense_id, expense_id)))
    :ok
  end

  defp names, do: Map.new(Repo.all(from p in Participant, select: {p.id, p.name}))
  defp category_names, do: Map.new(Repo.all(from c in Category, select: {c.id, c.name}))

  @doc "A blank expense form with everybody; options as `Zipfelkasse.Expenses.Form.new/2`."
  def new_form(opts), do: Form.new(Participants.list_participants(:all), opts)

  @doc "The form of a saved expense."
  def edit_form(%Expense{} = expense),
    do: Form.from_expense(expense, Participants.list_participants(:all))

  @doc "The split preview of a form; a new expense splits by the id it will get."
  def preview_form(%Form{} = form), do: Form.preview(form, form.expense_id || next_id())

  @doc "Looks up the rate of the form's currency on its date. Option `:today`."
  def lookup_form_rate(%Form{} = form, opts \\ []) do
    with {:ok, date} <- Dates.parse(form.date),
         currency = Form.currency_code(form),
         true <- Money.valid_currency?(currency) and currency != "EUR" do
      Form.put_rate(form, Fx.rate(currency, date, opts))
    else
      _invalid -> Changeset.change(form)
    end
  end

  @doc """
  Saves the form as a new expense or as `existing`. A foreign amount without a rate takes the
  rate of its date, as does one whose rate was looked up before, unless currency, date and rate
  are those saved; any other rate counts as manual. Errors come back on the form. Option
  `:today`.
  """
  def save_form(actor_id, %Form{} = form, existing \\ nil, opts \\ []) do
    with {:ok, input} <- Form.input(form),
         {:ok, form, input} <- resolve_rate(form, input, existing, opts) do
      result =
        if existing,
          do: update_expense(actor_id, existing, input),
          else: create_expense(actor_id, input)

      case result do
        {:error, %Changeset{} = changeset} -> {:error, Form.put_errors(form, changeset)}
        result -> result
      end
    end
  end

  defp resolve_rate(form, input, existing, opts) do
    cond do
      Money.eur?(input.original_currency) -> {:ok, form, input}
      input.fx_rate && form.rate_source != :ecb -> {:ok, form, %{input | fx_source: :manual}}
      input.fx_rate && saved_ecb_rate?(existing, input) -> {:ok, form, %{input | fx_source: :ecb}}
      true -> lookup_rate(form, input, opts)
    end
  end

  defp saved_ecb_rate?(%Expense{fx_source: :ecb} = expense, input) do
    expense.original_currency == input.original_currency and expense.date == input.date and
      expense.fx_rate == input.fx_rate
  end

  defp saved_ecb_rate?(_existing, _input), do: false

  defp lookup_rate(form, %{original_currency: currency, date: date} = input, opts) do
    case Fx.rate(currency, date, opts) do
      {:ok, rate} ->
        form = form |> Form.put_rate({:ok, rate}) |> Changeset.apply_changes()
        {:ok, form, %{input | fx_rate: rate.rate, fx_source: rate.source}}

      {:error, _reason} = error ->
        changeset =
          form
          |> Form.put_rate(error)
          |> Changeset.add_error(
            :rate,
            "Für #{currency} ist am #{Dates.format(date)} kein Wechselkurs verfügbar. " <>
              "Kurs bitte von Hand eintragen."
          )

        {:error, %{changeset | action: :validate}}
    end
  end

  @doc """
  The id the next expense gets, by which the preview of a new expense splits its cents. Ids are
  never reused, not even those of rolled back inserts.
  """
  def next_id do
    %{rows: [[id]]} =
      Repo.query!("""
      SELECT max(coalesce((SELECT seq FROM sqlite_sequence WHERE name = 'expenses'), 0),
                 coalesce((SELECT max(id) FROM expenses), 0)) + 1
      """)

    id
  end

  @doc """
  A live expense that the input probably duplicates: same date, payer and euro amount, and the
  same title regardless of case, or for a reimbursement the same recipient. Nil for none or an
  invalid input.
  """
  def find_duplicate(attrs) do
    changeset = Expense.changeset(%Expense{}, attrs)

    if changeset.valid? do
      candidate = Changeset.apply_changes(changeset)

      from(e in Expense,
        where:
          is_nil(e.deleted_at) and e.date == ^candidate.date and
            e.paid_by_id == ^candidate.paid_by_id and e.amount_cents == ^candidate.amount_cents and
            e.reimbursement == ^candidate.reimbursement,
        order_by: [desc: e.id],
        limit: 1,
        preload: ^@preloads
      )
      |> same_title_or_recipient(candidate)
      |> Repo.one()
    end
  end

  defp same_title_or_recipient(query, %Expense{
         reimbursement: true,
         parts: [%{participant_id: recipient}]
       }) do
    join(query, :inner, [e], s in ExpenseShare,
      on: s.expense_id == e.id and s.participant_id == ^recipient and s.amount_cents != 0
    )
  end

  defp same_title_or_recipient(query, candidate),
    do: where(query, [e], e.title_folded == ^candidate.title_folded)

  @doc "`{title, category_id}` of the live expenses with an active category, newest first."
  def category_history do
    Repo.all(
      from e in Expense,
        join: c in assoc(e, :category),
        where: is_nil(e.deleted_at) and not e.reimbursement and is_nil(c.archived_at),
        order_by: [desc: e.date, desc: e.id],
        select: {e.title, e.category_id}
    )
  end

  @doc "The category suggestions learned from `category_history/0`."
  def category_suggestions, do: Suggestions.build(category_history())

  @doc "The number of live expenses each person paid or shares, by participant id."
  def count_by_participant do
    paid =
      from e in Expense,
        where: is_nil(e.deleted_at),
        select: %{participant_id: e.paid_by_id, id: e.id}

    shared =
      from s in ExpenseShare,
        join: e in assoc(s, :expense),
        where: is_nil(e.deleted_at),
        select: %{participant_id: s.participant_id, id: e.id}

    Repo.all(
      from u in subquery(union_all(paid, ^shared)),
        group_by: u.participant_id,
        select: {u.participant_id, count(u.id, :distinct)}
    )
    |> Map.new()
  end

  @doc """
  An overview of the live entries: the number of expenses and reimbursements, the expenses
  without category, and the first and last date (nil without entries).
  """
  def overview do
    Repo.one(
      from e in Expense,
        where: is_nil(e.deleted_at),
        select: %{
          expenses: fragment("coalesce(sum(? = 0), 0)", e.reimbursement),
          reimbursements: fragment("coalesce(sum(? = 1), 0)", e.reimbursement),
          without_category:
            fragment("coalesce(sum(? = 0 AND ? IS NULL), 0)", e.reimbursement, e.category_id),
          first_date: min(e.date),
          last_date: max(e.date)
        }
    )
  end

  @doc "The number of live expenses in each category, by category id."
  def count_by_category do
    Repo.all(
      from e in Expense,
        where: is_nil(e.deleted_at) and not is_nil(e.category_id),
        group_by: e.category_id,
        select: {e.category_id, count()}
    )
    |> Map.new()
  end
end
