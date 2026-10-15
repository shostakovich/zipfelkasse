defmodule Zipfelkasse.Fixtures do
  @moduledoc """
  Test data: Anna, Ben and Cleo with the seeded categories (Lebensmittel first, Restaurant
  second), and expense inputs among them.
  """

  alias Zipfelkasse.{Categories, Expenses, Participants}

  def household do
    [anna, ben, cleo] =
      for name <- ~w(Anna Ben Cleo) do
        {:ok, participant} = Participants.create_participant(nil, %{name: name})
        participant.id
      end

    [food, restaurant | _] = Categories.list_categories()
    %{anna: anna, ben: ben, cleo: cleo, food: food.id, restaurant: restaurant.id}
  end

  @doc "An equal split of `cents` among `people`, in the category Lebensmittel."
  def equal(household, title, cents, date, payer, people) do
    %{
      title: title,
      date: Date.from_iso8601!(date),
      category_id: household.food,
      paid_by_id: payer,
      amount_cents: cents,
      split_mode: :equal,
      parts: Enum.map(people, &%{participant_id: &1, weight: 0})
    }
  end

  @doc "A reimbursement of `cents` from `payer` to `recipient`."
  def reimbursement(cents, date, payer, recipient) do
    %{
      title: "Rückzahlung",
      date: Date.from_iso8601!(date),
      paid_by_id: payer,
      amount_cents: cents,
      reimbursement: true,
      parts: [%{participant_id: recipient, weight: 0}]
    }
  end

  @doc "`minor` units of `currency` at `rate`, an ECB rate, split equally among `people`."
  def foreign(household, title, minor, currency, rate, date, payer, people) do
    household
    |> equal(title, 0, date, payer, people)
    |> Map.merge(%{
      original_currency: currency,
      original_amount: minor,
      fx_rate: rate,
      fx_source: :ecb
    })
  end

  def create!(attrs, actor_id \\ nil) do
    {:ok, expense} = Expenses.create_expense(actor_id, attrs)
    expense
  end
end
