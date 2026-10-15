defmodule Zipfelkasse.Ynab.Plan do
  @moduledoc """
  What a sync run does: the desired postings (by expense id) against the stored transactions.
  Without a transaction it creates, with an outdated fingerprint it updates, and transactions
  no longer wanted are deleted, or forgotten if YNAB never got them. A failed transaction (with
  this fingerprint) and a failed deletion wait for the full sync.
  """

  alias Zipfelkasse.Ynab.{Transaction, Want}

  defstruct creates: [], updates: [], deletes: [], forget: []

  @type t :: %__MODULE__{
          creates: [Want.t()],
          updates: [{Want.t(), String.t()}],
          deletes: [Transaction.t()],
          forget: [integer()]
        }

  @spec build(%{integer() => Want.t()}, %{integer() => Transaction.t()}, boolean()) :: t()
  def build(wants, rows, full?) do
    {creates, updates} =
      Enum.reduce(wants, {[], []}, fn {id, want}, {creates, updates} ->
        case wanted(Map.get(rows, id), want, full?) do
          :create -> {[want | creates], updates}
          {:update, transaction_id} -> {creates, [{want, transaction_id} | updates]}
          :keep -> {creates, updates}
        end
      end)

    {deletes, forget} =
      rows
      |> Enum.reject(fn {id, _row} -> Map.has_key?(wants, id) end)
      |> Enum.reduce({[], []}, fn {id, row}, {deletes, forget} ->
        cond do
          is_nil(row.ynab_transaction_id) -> {deletes, [id | forget]}
          full? or row.state != :delete_failed -> {[row | deletes], forget}
          true -> {deletes, forget}
        end
      end)

    %__MODULE__{
      creates: Enum.sort_by(creates, &Want.expense_id/1),
      updates: Enum.sort_by(updates, fn {want, _id} -> Want.expense_id(want) end),
      deletes: Enum.sort_by(deletes, & &1.expense_id),
      forget: Enum.sort(forget)
    }
  end

  defp wanted(row, want, full?) do
    cond do
      not full? and at?(row, :failed, want) -> :keep
      is_nil(row) or is_nil(row.ynab_transaction_id) -> :create
      not at?(row, :synced, want) -> {:update, row.ynab_transaction_id}
      true -> :keep
    end
  end

  defp at?(nil, _state, _want), do: false

  defp at?(%Transaction{} = row, state, want),
    do: row.state == state and row.fingerprint == want.fingerprint
end
