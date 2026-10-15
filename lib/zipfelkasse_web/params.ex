defmodule ZipfelkasseWeb.Params do
  @moduledoc "Values read from request params."

  @doc ~s(A positive integer such as an id: `"42"` is 42, anything else nil.)
  @spec positive_integer(term()) :: pos_integer() | nil
  def positive_integer(text) when is_binary(text) do
    case Integer.parse(text) do
      {number, ""} when number > 0 -> number
      _invalid -> nil
    end
  end

  def positive_integer(_text), do: nil
end
