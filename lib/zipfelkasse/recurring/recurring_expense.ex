defmodule Zipfelkasse.Recurring.RecurringExpense do
  @moduledoc """
  A rule that repeats an expense weekly, monthly or yearly. Its template is the expense as
  entered, without date; occurrences are counted from `start_date`, `next_date` is the next due.
  """

  use Zipfelkasse.Schema

  import Ecto.Changeset

  alias Zipfelkasse.Participants.Participant

  schema "recurring_expenses" do
    embeds_one :template, Template, primary_key: false, on_replace: :update do
      field :title, :string, default: ""
      field :category_id, :integer
      field :paid_by_id, :integer
      field :notes, :string, default: ""
      field :reimbursement, :boolean, default: false
      field :split_mode, Ecto.Enum, values: [:equal, :shares, :percent, :amount], default: :equal
      field :amount_cents, :integer, default: 0
      field :original_amount, :integer, default: 0
      field :original_currency, :string, default: "EUR"
      field :fx_rate, :float
      field :fx_source, Ecto.Enum, values: [:ecb, :manual]

      embeds_many :parts, Part, primary_key: false, on_replace: :delete do
        field :participant_id, :integer
        field :weight, :integer, default: 0
      end
    end

    field :frequency, Ecto.Enum, values: [:weekly, :monthly, :yearly]
    field :start_date, :date
    field :next_date, :date
    field :active, :boolean, default: true
    belongs_to :created_by, Participant

    timestamps()
  end

  @template_fields [
    :title,
    :category_id,
    :paid_by_id,
    :notes,
    :reimbursement,
    :split_mode,
    :amount_cents,
    :original_amount,
    :original_currency,
    :fx_rate,
    :fx_source
  ]

  @doc "The fields of a template: those of an expense input but date and parts."
  def template_fields, do: @template_fields

  @doc "A template from an expense input (see `Zipfelkasse.Expenses.input/1`)."
  def template_changeset(template, attrs) do
    template
    |> cast(attrs, @template_fields, empty_values: [])
    |> cast_embed(:parts, with: &part_changeset/2)
  end

  defp part_changeset(part, attrs), do: cast(part, attrs, [:participant_id, :weight])
end
