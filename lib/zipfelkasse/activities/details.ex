defmodule Zipfelkasse.Activities.Details do
  @moduledoc """
  The details of an activity entry: the expense's title and amount, the changed fields of an
  update, or a text. Stored as JSON in that order without empty fields, read back as this struct.
  """

  use Ecto.Type

  alias Zipfelkasse.OrderedJSON

  defmodule Change do
    @moduledoc "A changed field of an expense with its old and new value, as shown."
    defstruct [:field, :old, :new]

    @type t :: %__MODULE__{field: String.t(), old: String.t(), new: String.t()}
  end

  defstruct title: nil, amount_cents: nil, text: nil, changes: []

  @type t :: %__MODULE__{
          title: String.t() | nil,
          amount_cents: integer() | nil,
          text: String.t() | nil,
          changes: [Change.t()]
        }

  @impl true
  def type, do: :map

  @impl true
  def cast(%__MODULE__{} = details), do: {:ok, details}
  def cast(%{} = details), do: {:ok, new(details)}
  def cast(_other), do: :error

  @impl true
  def load(%{} = stored) do
    {:ok,
     %__MODULE__{
       title: stored["title"],
       amount_cents: stored["amount_cents"],
       text: stored["text"],
       changes:
         for change <- stored["changes"] || [] do
           %Change{field: change["field"], old: change["old"], new: change["new"]}
         end
     }}
  end

  def load(_other), do: :error

  @impl true
  def dump(%__MODULE__{} = details) do
    stored =
      [
        title: details.title,
        amount_cents: details.amount_cents,
        changes: for(c <- details.changes, do: [field: c.field, old: c.old, new: c.new]),
        text: details.text
      ]
      |> Enum.reject(fn {_key, value} -> value in [nil, []] end)

    # The adapter stores a binary as it is; a map it would encode with sorted keys.
    {:ok, if(stored == [], do: "{}", else: OrderedJSON.encode!(stored))}
  end

  def dump(_other), do: :error

  @doc "Details from a map with `:title`, `:amount_cents`, `:text` and `:changes` (maps)."
  @spec new(map()) :: t()
  def new(details) do
    %__MODULE__{
      title: details[:title],
      amount_cents: details[:amount_cents],
      text: details[:text],
      changes: Enum.map(details[:changes] || [], &struct(Change, &1))
    }
  end
end
