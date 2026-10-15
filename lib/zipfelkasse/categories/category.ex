defmodule Zipfelkasse.Categories.Category do
  @moduledoc """
  A category of expenses, ordered by position. Categories are archived, never deleted: old
  expenses keep them.
  """

  use Zipfelkasse.Schema

  import Ecto.Changeset

  alias Zipfelkasse.Names

  schema "categories" do
    field :name, :string
    field :position, :integer, default: 0
    field :archived_at, :utc_datetime_usec

    timestamps()
  end

  @doc "A new name; unique regardless of case."
  def changeset(category, attrs) do
    changeset =
      category
      |> cast(attrs, [:name])
      |> Names.validate(:name, "die Kategorie")

    unique_constraint(changeset, :name,
      message: "Die Kategorie „#{get_field(changeset, :name)}“ gibt es schon."
    )
  end

  @doc "Whether the category is archived."
  def archived?(%__MODULE__{archived_at: archived_at}), do: not is_nil(archived_at)
end
