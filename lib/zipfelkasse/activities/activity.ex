defmodule Zipfelkasse.Activities.Activity do
  @moduledoc """
  An entry of the activity log: who did what, when. No actor means it happened automatically.
  The details hold the expense's title and amount, the changed fields of an update, or a text;
  all German as shown.
  """

  use Zipfelkasse.Schema

  alias Zipfelkasse.Activities.Details
  alias Zipfelkasse.Expenses.Expense
  alias Zipfelkasse.Participants.Participant

  @actions [
    :expense_created,
    :expense_updated,
    :expense_deleted,
    :settings_updated,
    :recurring_created,
    :recurring_deleted
  ]

  schema "activities" do
    belongs_to :actor, Participant
    field :action, Ecto.Enum, values: @actions
    belongs_to :expense, Expense
    field :details, Details, default: %Details{}

    timestamps(updated_at: false)
  end
end
