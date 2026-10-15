defmodule Zipfelkasse.MCP.Directory do
  @moduledoc """
  The people and categories the tools refer to by name, regardless of case. Lookups list all
  people, archived ones too; new entries take only active people.
  """

  alias Zipfelkasse.{Categories, Participants}
  alias Zipfelkasse.MCP.ToolError

  defstruct people: [], names: %{}

  @doc "Everybody, by name."
  def load do
    people = Participants.list_participants(:all)
    %__MODULE__{people: people, names: Map.new(people, &{&1.id, &1.name})}
  end

  @doc "The name of a participant id, `\"\"` if unknown."
  def name(%__MODULE__{names: names}, id), do: Map.get(names, id, "")

  @doc "A text argument without surrounding whitespace, nil if empty."
  def given(nil), do: nil

  def given(text) do
    case String.trim(text) do
      "" -> nil
      text -> text
    end
  end

  @doc "The person named `name`, archived ones too, nil without a name; refuses an unknown one."
  def find(%__MODULE__{people: people}, name) do
    if name = given(name), do: find_named(people, "person", name)
  end

  @doc "An active person for a new entry; `argument` names the argument in refusals."
  def active(%__MODULE__{people: people}, argument, name) do
    name = given(name) || ToolError.raise!("Parameter #{argument} is missing.")

    case Enum.find(people, &same?(&1.name, name)) do
      %{archived_at: nil} = person ->
        person

      %{} = person ->
        ToolError.raise!("#{person.name} is archived and cannot take part in new entries.")

      nil ->
        available =
          people |> Enum.filter(&is_nil(&1.archived_at)) |> Enum.map_join(", ", & &1.name)

        ToolError.raise!(
          "Unknown person #{inspect(name)} in #{argument}. Available: #{available}."
        )
    end
  end

  @doc "The category named `name`, archived ones too; refuses an unknown one."
  def category(name), do: find_named(Categories.list_categories(:all), "category", name)

  defp find_named(items, kind, name) do
    name = String.trim(name)

    Enum.find(items, &same?(&1.name, name)) ||
      ToolError.raise!(
        "Unknown #{kind} #{inspect(name)}. Available: #{Enum.map_join(items, ", ", & &1.name)}."
      )
  end

  defp same?(a, b), do: String.downcase(a) == String.downcase(b)
end
