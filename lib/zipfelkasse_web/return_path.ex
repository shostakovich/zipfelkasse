defmodule ZipfelkasseWeb.ReturnPath do
  @moduledoc """
  Where to go after choosing a person: a path of this app, or the start page. Query and fragment
  stay as they are.
  """

  @doc """
  The target if it is a local path, otherwise `"/"`. Refused are backslashes and control
  characters, `//` (also percent-encoded), broken percent escapes and the person choice itself
  (anything starting with `/who`).
  """
  @spec safe(String.t() | nil) :: String.t()
  def safe(target) when is_binary(target) do
    {rest, fragment} = split(target, "#")
    {path, _query} = split(rest, "?")

    if local?(target) and escaped?(path) and escaped?(fragment) and
         allowed?(URI.decode(path)),
       do: target,
       else: "/"
  end

  def safe(_target), do: "/"

  defp split(text, separator) do
    case String.split(text, separator, parts: 2) do
      [before, rest] -> {before, rest}
      [before] -> {before, ""}
    end
  end

  defp local?(target) do
    String.starts_with?(target, "/") and not String.starts_with?(target, "//") and clean?(target)
  end

  defp allowed?(decoded) do
    clean?(decoded) and not String.starts_with?(decoded, "//") and
      not String.starts_with?(decoded, "/who")
  end

  defp clean?(text), do: String.valid?(text) and not String.match?(text, ~r/[\\\p{Cc}]/u)

  defp escaped?(text) do
    text |> String.split("%") |> tl() |> Enum.all?(&(&1 =~ ~r/\A[0-9A-Fa-f]{2}/))
  end
end
