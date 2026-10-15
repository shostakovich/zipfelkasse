defmodule Zipfelkasse.Settings.Setting do
  @moduledoc "The settings of the group, a single row."

  use Zipfelkasse.Schema

  import Ecto.Changeset

  alias Zipfelkasse.Names

  @primary_key {:id, :integer, autogenerate: false}
  schema "settings" do
    field :group_name, :string

    timestamps()
  end

  @doc "A new group name."
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:group_name])
    |> Names.validate(:group_name, "die Gruppe")
  end
end
