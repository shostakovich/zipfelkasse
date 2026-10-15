defmodule Zipfelkasse.Ynab.CategoryMapping do
  @moduledoc "The YNAB category a person's shares of a category are booked to."

  use Zipfelkasse.Schema

  alias Zipfelkasse.Categories.Category
  alias Zipfelkasse.Participants.Participant

  @primary_key false
  schema "ynab_category_mappings" do
    belongs_to :participant, Participant, primary_key: true
    belongs_to :category, Category, primary_key: true
    field :ynab_category_id, :string
  end
end
