defmodule Zipfelkasse.Ynab.Transaction do
  @moduledoc """
  The YNAB transaction of a person's share of an expense, with the fingerprint of what was last
  sent and the state of its sync.
  """

  use Zipfelkasse.Schema

  alias Zipfelkasse.Expenses.Expense
  alias Zipfelkasse.Participants.Participant

  @type t :: %__MODULE__{}

  @primary_key false
  schema "ynab_transactions" do
    belongs_to :expense, Expense, primary_key: true
    belongs_to :participant, Participant, primary_key: true
    field :ynab_transaction_id, :string

    field :state, Ecto.Enum,
      values: [:unknown, :synced, :pending, :retarget, :failed, :delete_failed],
      default: :unknown

    field :fingerprint, :string
    field :synced_at, :utc_datetime_usec
    field :last_error, :string
  end
end
