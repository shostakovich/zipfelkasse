defmodule Zipfelkasse.Participants.Participant do
  @moduledoc "A person of the group. People are archived, never deleted: old expenses keep them."

  use Zipfelkasse.Schema

  import Ecto.Changeset

  alias Zipfelkasse.Names

  schema "participants" do
    field :name, :string
    field :archived_at, :utc_datetime_usec

    timestamps()
  end

  @doc "A new name; unique regardless of case."
  def changeset(participant, attrs) do
    changeset =
      participant
      |> cast(attrs, [:name])
      |> Names.validate(:name, "die Person")

    unique_constraint(changeset, :name,
      message: "„#{get_field(changeset, :name)}“ gibt es schon."
    )
  end

  @doc "Whether the person is archived."
  def archived?(%__MODULE__{archived_at: archived_at}), do: not is_nil(archived_at)
end
