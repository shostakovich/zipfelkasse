defmodule Zipfelkasse.Ynab.Result do
  @moduledoc "The counts of a run; `again` asks for another run soon."
  defstruct created: 0, updated: 0, deleted: 0, failed: 0, again: false

  @type t :: %__MODULE__{}

  @doc "The number of changes, failures included."
  def changes(%__MODULE__{} = r), do: r.created + r.updated + r.deleted + r.failed

  @doc ~s(As shown: "1 neu · 0 geändert · 0 gelöscht", failures only if there are any.)
  def summary(%__MODULE__{} = r) do
    text = "#{r.created} neu · #{r.updated} geändert · #{r.deleted} gelöscht"
    if r.failed > 0, do: text <> " · #{r.failed} fehlgeschlagen", else: text
  end
end
