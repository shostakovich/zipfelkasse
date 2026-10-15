defmodule Zipfelkasse.Ynab.Want do
  @moduledoc """
  A posting as it should be in YNAB, with the mapped YNAB category, and the fingerprint by which
  the sync sees whether YNAB has it like this already.
  """

  alias Zipfelkasse.Ynab.Posting

  @hash_version "v1"

  @enforce_keys [:posting, :category, :fingerprint]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          posting: Posting.t(),
          category: String.t() | nil,
          fingerprint: String.t()
        }

  def new(%Posting{} = posting, category),
    do: %__MODULE__{
      posting: posting,
      category: category,
      fingerprint: fingerprint(posting, category)
    }

  @doc """
  The hex of the first 16 bytes of the SHA-256 of the fields. Stored fingerprints are compared
  with it, so it must never change, or every transaction looks changed and gets updated.
  """
  def fingerprint(%Posting{} = posting, category) do
    data =
      Enum.join(
        [
          @hash_version,
          Date.to_iso8601(posting.date),
          Integer.to_string(Posting.milliunits(posting)),
          posting.payee,
          posting.memo,
          category || ""
        ],
        <<0>>
      )

    :sha256 |> :crypto.hash(data) |> binary_part(0, 16) |> Base.encode16(case: :lower)
  end

  def expense_id(%__MODULE__{posting: posting}), do: posting.expense_id

  @doc "A new transaction in `account_id`, cleared and approved. Never with an import id."
  def new_transaction(%__MODULE__{} = want, account_id) do
    want
    |> fields()
    |> Map.merge(%{account_id: account_id, cleared: "cleared", approved: true})
  end

  @doc """
  The change of transaction `id`. It keeps cleared and approved as they are (e.g. reconciled),
  and a category set by hand in YNAB unless one is mapped.
  """
  def patch_transaction(%__MODULE__{} = want, id), do: want |> fields() |> Map.put(:id, id)

  # An import id would let YNAB merge the transaction with a reimbursement transfer of equal amount.
  defp fields(%__MODULE__{posting: posting, category: category}) do
    fields = %{
      date: Date.to_iso8601(posting.date),
      amount: Posting.milliunits(posting),
      payee_name: posting.payee,
      memo: posting.memo
    }

    if category, do: Map.put(fields, :category_id, category), else: fields
  end
end
