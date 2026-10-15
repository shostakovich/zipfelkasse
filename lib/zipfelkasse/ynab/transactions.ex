defmodule Zipfelkasse.Ynab.Transactions do
  @moduledoc """
  The stored state of each synced share: the YNAB transaction, the fingerprint last sent and
  what became of the last attempt. A pending transaction was being created with an unknown
  outcome, a retargeted one belongs to another plan or account; both are looked up by their memo
  marker before anything is created again.
  """

  import Ecto.Query

  alias Zipfelkasse.Expenses.Expense
  alias Zipfelkasse.Repo
  alias Zipfelkasse.Ynab.Transaction

  @fields [:ynab_transaction_id, :state, :fingerprint, :synced_at, :last_error]

  @doc "The transactions of a person, by expense id."
  def list(participant_id) do
    Repo.all(
      from t in Transaction, where: t.participant_id == ^participant_id, order_by: t.expense_id
    )
  end

  @doc "Inserts or replaces transactions."
  def put([]), do: :ok

  def put(transactions) do
    transactions
    |> Enum.map(&Map.take(&1, [:expense_id, :participant_id | @fields]))
    |> Enum.chunk_every(500)
    |> Enum.each(fn chunk ->
      Repo.insert_all(Transaction, chunk,
        on_conflict: {:replace, @fields},
        conflict_target: [:expense_id, :participant_id]
      )
    end)
  end

  @doc "Forgets the transactions of a person's shares of `expense_ids`."
  def delete(_participant_id, []), do: :ok

  def delete(participant_id, expense_ids) do
    Repo.delete_all(
      from t in Transaction,
        where: t.participant_id == ^participant_id and t.expense_id in ^expense_ids
    )

    :ok
  end

  @doc """
  The number of a person's transactions in YNAB, and the expenses whose last attempt failed,
  newest first: `%{expense_id, title, date, error}`.
  """
  def summary(participant_id) do
    synced =
      Repo.aggregate(
        from(t in Transaction,
          where: t.participant_id == ^participant_id and not is_nil(t.ynab_transaction_id)
        ),
        :count
      )

    problems =
      Repo.all(
        from t in Transaction,
          join: e in Expense,
          on: e.id == t.expense_id,
          where: t.participant_id == ^participant_id and not is_nil(t.last_error),
          order_by: [desc: e.date, desc: e.id],
          select: %{expense_id: e.id, title: e.title, date: e.date, error: t.last_error}
      )

    {synced, problems}
  end
end
