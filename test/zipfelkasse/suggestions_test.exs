defmodule Zipfelkasse.SuggestionsTest do
  use ExUnit.Case, async: true

  alias Zipfelkasse.Suggestions

  @food 1
  @dining 2
  @home 3

  # The expenses, newest first, as {title, category, times}.
  defp history(entries),
    do:
      Enum.flat_map(entries, fn {title, category, times} ->
        List.duplicate({title, category}, times)
      end)

  describe "title_key/1" do
    for {title, key} <- [
          {"Kaufland", "kaufland"},
          {"  KAUFLAND  Mitte", "kaufland mitte"},
          {"Miete 03/24", "miete"},
          {"Bäckerei-Müller!", "bäckerei müller"},
          {"2024", ""}
        ] do
      test "turns #{inspect(title)} into #{inspect(key)}" do
        assert Suggestions.title_key(unquote(title)) == unquote(key)
      end
    end
  end

  describe "learning from the recent history" do
    test "suggests the category a title was used with most often, regardless of its case, and ignores an outlier" do
      suggestions =
        Suggestions.build(
          history([{"Kaufland", @food, 2}, {"kaufland", @dining, 1}, {"Kaufland", @food, 3}])
        )

      assert suggestions.titles["kaufland"] == @food
    end

    test "suggests the most recent category on a tie" do
      assert Suggestions.build(history([{"DM", @home, 1}, {"dm", @food, 1}])).titles["dm"] ==
               @home
    end

    test "counts only the recent history" do
      suggestions =
        Suggestions.build(
          history([{"Rewe", @dining, 3}, {"Rewe", @food, 7}, {"Rewe", @dining, 10}])
        )

      assert suggestions.titles["rewe"] == @food
    end

    test "does not suggest a category for a part of a title" do
      refute Map.has_key?(Suggestions.build(history([{"Aldi Süd", @food, 1}])).titles, "aldi")
    end

    test "suggests a category for every word of a title, with the support of the category" do
      suggestions = Suggestions.build(history([{"Kaufland", @food, 5}, {"Aldi Süd", @food, 1}]))

      assert Map.take(suggestions.words, ~w(kaufland aldi süd)) ==
               %{"kaufland" => {@food, 5}, "aldi" => {@food, 1}, "süd" => {@food, 1}}
    end
  end

  test "makes no suggestion for an ambiguous word or a filler word" do
    words =
      Suggestions.build([
        {"dm", @home},
        {"DM", @food},
        {"Brot und Butter", @food},
        {"Brot und Käse", @food}
      ]).words

    refute Map.has_key?(words, "dm")
    refute Map.has_key?(words, "und")
  end

  test "counts a word once per title" do
    assert Suggestions.build([{"Rewe Rewe", @food}]).words["rewe"] == {@food, 1}
  end

  describe "suggest/2" do
    setup do
      %{
        suggestions:
          Suggestions.build(
            history([{"Kaufland", @food, 3}, {"Kino am Markt", @dining, 2}, {"Markt", @home, 1}])
          )
      }
    end

    test "suggests by the whole title first", %{suggestions: suggestions} do
      assert Suggestions.suggest(suggestions, "MARKT") == @home
    end

    test "else by the word with the most support", %{suggestions: suggestions} do
      assert Suggestions.suggest(suggestions, "Kaufland Markt") == @food
      assert Suggestions.suggest(suggestions, "Kino") == @dining
    end

    test "suggests nothing for an unknown title", %{suggestions: suggestions} do
      assert Suggestions.suggest(suggestions, "Tankstelle") == nil
      assert Suggestions.suggest(suggestions, "") == nil
    end
  end
end
