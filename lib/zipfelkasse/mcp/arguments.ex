defmodule Zipfelkasse.MCP.Arguments do
  @moduledoc """
  Strict decoding of tool arguments: an object with only the known properties, each of its type.
  A null counts as not given. Choices match regardless of case and underscores, as in
  "DATE_ASC". Errors name the property.

  Types: `:string`, `:integer`, `:number`, `:boolean`, `{:choice, values}`, `:text_or_list` (one
  or more strings), `:strings`, `:amount` (a string or a number, kept as written), `:weights`
  (an object of amounts). A property `{name, type, required: true}` must be given.
  """

  alias Zipfelkasse.MCP.ToolError

  @defaults %{text_or_list: [], strings: [], weights: %{}, boolean: false}

  @doc "The arguments by property name (atoms); raises a `Zipfelkasse.MCP.ToolError`."
  def decode!(nil, properties), do: decode!(%{}, properties)

  def decode!(%{} = arguments, properties) do
    names = Map.new(properties, fn {name, _type, _opts} -> {Atom.to_string(name), name} end)

    case Enum.find(Map.keys(arguments), &(not Map.has_key?(names, &1))) do
      nil -> :ok
      unknown -> invalid!(unknown, "unknown argument")
    end

    Map.new(properties, fn {name, type, opts} ->
      case {Map.get(arguments, Atom.to_string(name)), opts[:required]} do
        {nil, true} -> invalid!(name, "missing")
        {nil, _optional} -> {name, default(type)}
        {value, _required} -> {name, value!(name, value, type)}
      end
    end)
  end

  def decode!(_arguments, _properties),
    do: ToolError.raise!("Invalid arguments: expected an object")

  defp value!(name, value, type) do
    case value(value, type) do
      {:ok, value} -> value
      :error -> invalid!(name, "expected #{expected(type)}")
    end
  end

  defp invalid!(name, problem), do: ToolError.raise!("Invalid arguments: #{name}: #{problem}")

  defp default(type) when is_atom(type), do: Map.get(@defaults, type)
  defp default(_type), do: nil

  defp value(value, :string) when is_binary(value), do: {:ok, value}
  defp value(value, :integer) when is_integer(value), do: {:ok, value}
  defp value(value, :number) when is_number(value), do: {:ok, value / 1}
  defp value(value, :boolean) when is_boolean(value), do: {:ok, value}
  defp value(value, :text_or_list) when is_binary(value), do: {:ok, [value]}

  defp value(values, :text_or_list) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) or is_nil(&1))),
      do: {:ok, Enum.reject(values, &is_nil/1)},
      else: :error
  end

  defp value(values, :strings) when is_list(values),
    do: if(Enum.all?(values, &is_binary/1), do: {:ok, values}, else: :error)

  defp value(value, :amount), do: amount(value)

  defp value(%{} = weights, :weights) do
    amounts = Map.new(weights, fn {name, value} -> {name, amount(value)} end)

    if Enum.all?(Map.values(amounts), &match?({:ok, _amount}, &1)),
      do: {:ok, Map.new(amounts, fn {name, {:ok, amount}} -> {name, amount} end)},
      else: :error
  end

  defp value(value, {:choice, values}) when is_binary(value) do
    case Enum.find(values, &(normalize(Atom.to_string(&1)) == normalize(value))) do
      nil -> :error
      choice -> {:ok, choice}
    end
  end

  defp value(_value, _type), do: :error

  defp normalize(text), do: text |> String.replace("_", "") |> String.downcase()

  defp amount(value) when is_binary(value), do: {:ok, value}
  defp amount(value) when is_integer(value), do: {:ok, Integer.to_string(value)}
  defp amount(value) when is_float(value), do: {:ok, Float.to_string(value)}
  defp amount(_value), do: :error

  defp expected(:string), do: "a string"
  defp expected(:integer), do: "an integer"
  defp expected(:number), do: "a number"
  defp expected(:boolean), do: "true or false"
  defp expected(:text_or_list), do: "a string or a list of strings"
  defp expected(:strings), do: "a list of strings"
  defp expected(:amount), do: "a string or a number"
  defp expected(:weights), do: "an object of names and amounts"
  defp expected({:choice, values}), do: "one of " <> Enum.join(values, ", ")
end
