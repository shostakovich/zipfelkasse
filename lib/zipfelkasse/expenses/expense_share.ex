defmodule Zipfelkasse.Expenses.ExpenseShare do
  @moduledoc """
  A person's share of an expense in euro cents, with the weight it was split by (see
  `Zipfelkasse.Split`). The shares of an expense add up to its amount.
  """

  use Zipfelkasse.Schema

  alias Zipfelkasse.Expenses.Expense
  alias Zipfelkasse.Participants.Participant

  @primary_key false
  schema "expense_shares" do
    belongs_to :expense, Expense, primary_key: true
    belongs_to :participant, Participant, primary_key: true
    field :weight, :integer
    field :amount_cents, :integer
  end
end
