defmodule Zipfelkasse.Suggestions do
  @moduledoc """
  The category to suggest for an expense title, learned from earlier expenses. A title (as its
  key: the lower-case runs of letters) suggests the category it was used with most often among
  its last ten expenses, on a tie the most recent one. Otherwise a single word of the title
  suggests a category if two thirds of its last ten expenses agree; filler words never do.
  """

  # Newer habits win after a few expenses; single outliers do not matter.
  @window 10
  @fillers MapSet.new(~w(und oder für mit ohne bei von vom zu zum zur in im an am auf aus nach
                         über der die das den dem des ein eine einen einem einer))

  @type t :: %{
          titles: %{String.t() => integer()},
          words: %{String.t() => {integer(), pos_integer()}}
        }

  @doc "The key of a title: its runs of letters in lower case, joined by single spaces."
  @spec title_key(String.t()) :: String.t()
  def title_key(title) do
    ~r/\p{L}+/u
    |> Regex.scan(String.downcase(title))
    |> Enum.map_join(" ", &hd/1)
  end

  @doc "Learns from `history`, `{title, category_id}` pairs of the expenses, newest first."
  @spec build([{String.t(), integer()}]) :: t()
  def build(history) do
    {titles, words} =
      Enum.reduce(history, {%{}, %{}}, fn {title, category_id}, {titles, words} ->
        key = title_key(title)

        words =
          key
          |> String.split(" ", trim: true)
          |> Enum.uniq()
          |> Enum.reject(&(&1 in @fillers))
          |> Enum.reduce(words, &remember(&2, &1, category_id))

        {remember(titles, key, category_id), words}
      end)

    %{
      titles: Map.new(titles, fn {key, recent} -> {key, recent |> majority() |> elem(0)} end),
      words: clear_majorities(words)
    }
  end

  # A single word needs two thirds: "dm" for household and groceries alike suggests nothing.
  defp clear_majorities(words) do
    for {word, recent} <- words,
        {category_id, count} <- [majority(recent)],
        3 * count >= 2 * length(recent),
        into: %{},
        do: {word, {category_id, count}}
  end

  defp remember(map, "", _category_id), do: map

  defp remember(map, key, category_id) do
    Map.update(map, key, [category_id], fn recent ->
      if length(recent) < @window, do: recent ++ [category_id], else: recent
    end)
  end

  defp majority([newest | _] = recent) do
    counts = Enum.frequencies(recent)

    best =
      Enum.reduce(recent, newest, fn category_id, best ->
        if counts[category_id] > counts[best], do: category_id, else: best
      end)

    {best, counts[best]}
  end

  @doc "The category to suggest for `title`, or nil."
  @spec suggest(t(), String.t()) :: integer() | nil
  def suggest(%{titles: titles, words: words}, title) do
    key = title_key(title)
    Map.get(titles, key) || strongest_word(words, String.split(key, " ", trim: true))
  end

  defp strongest_word(words, title_words) do
    title_words
    |> Enum.map(&Map.get(words, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce({nil, 0}, fn {category_id, count}, {_best, support} = best ->
      if count > support, do: {category_id, count}, else: best
    end)
    |> elem(0)
  end
end
