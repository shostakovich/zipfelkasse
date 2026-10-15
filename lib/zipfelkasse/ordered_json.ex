defmodule Zipfelkasse.OrderedJSON do
  @moduledoc """
  JSON whose objects keep their key order: a non-empty keyword list becomes an object with its
  keys in that order. Everything else encodes as with `JSON`, `nil` as null.
  """

  @doc "Compact JSON."
  @spec encode!(term()) :: String.t()
  def encode!(term), do: JSON.encode!(term, &encode/2)

  defp encode([{key, _value} | _rest] = pairs, encoder) when is_atom(key),
    do: :json.encode_key_value_list(pairs, encoder)

  defp encode(value, encoder), do: JSON.protocol_encode(value, encoder)

  @doc "JSON indented by two spaces, ending with a newline."
  @spec format!(term()) :: String.t()
  def format!(term), do: term |> :json.format(&format/3, %{indent: 2}) |> IO.iodata_to_binary()

  defp format([{key, _value} | _rest] = pairs, formatter, state) when is_atom(key),
    do: :json.format_key_value_list(pairs, formatter, state)

  defp format(nil, formatter, state), do: :json.format_value(:null, formatter, state)
  defp format(value, formatter, state), do: :json.format_value(value, formatter, state)
end
