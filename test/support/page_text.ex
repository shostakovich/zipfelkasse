defmodule ZipfelkasseWeb.PageText do
  @moduledoc """
  The text of a page's elements as a reader sees it: no-break spaces as spaces, word joiners
  dropped, runs of whitespace collapsed. A page is a LiveView or a parsed document.
  """

  @doc "The text of every element matching `selector`."
  def texts(page, selector) do
    for node <- page |> parse() |> LazyHTML.query(selector),
        do: node |> LazyHTML.text() |> squish()
  end

  @doc "The text of the one element matching `selector`."
  def text(page, selector) do
    [text] = texts(page, selector)
    text
  end

  @doc "The text of the flash of `kind` (`:info` or `:error`), or nil."
  def flash(view, kind), do: view |> texts("#flash-group #flash-#{kind} p") |> List.first()

  def squish(text) do
    text
    |> String.replace("\u2060", "")
    |> String.replace("\u00A0", " ")
    |> String.split()
    |> Enum.join(" ")
  end

  defp parse(%LazyHTML{} = document), do: document
  defp parse(view), do: view |> Phoenix.LiveViewTest.render() |> LazyHTML.from_fragment()
end
