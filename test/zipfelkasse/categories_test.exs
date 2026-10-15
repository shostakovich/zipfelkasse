defmodule Zipfelkasse.CategoriesTest do
  use Zipfelkasse.DataCase

  import Zipfelkasse.ActivityTexts

  alias Zipfelkasse.Categories

  defp names, do: Enum.map(Categories.list_categories(), & &1.name)

  defp create!(name) do
    {:ok, category} = Categories.create_category(nil, %{name: name})
    category
  end

  test "lists the seeded categories in their order" do
    assert names() == [
             "Lebensmittel",
             "Restaurant",
             "Haushalt",
             "Miete & Nebenkosten",
             "Transport",
             "Reisen",
             "Freizeit",
             "Gesundheit",
             "Geschenke",
             "Sonstiges"
           ]
  end

  test "puts a new category before Sonstiges and renumbers the positions" do
    category = create!(" Haus  tiere ")

    assert Enum.take(names(), -2) == ["Haus tiere", "Sonstiges"]
    assert category.position == 100
    assert Enum.map(Categories.list_categories(), & &1.position) == Enum.map(1..11, &(&1 * 10))
    assert activity_texts(:oldest_first) == ["Kategorie „Haus tiere“ hinzugefügt"]
  end

  test "refuses the name of an existing category, regardless of its case" do
    assert {:error, changeset} = Categories.create_category(nil, %{name: "lebensmittel"})
    assert errors_on(changeset) == %{name: ["Die Kategorie „lebensmittel“ gibt es schon."]}
    assert {:error, changeset} = Categories.create_category(nil, %{name: ""})
    assert errors_on(changeset) == %{name: ["Bitte einen Namen für die Kategorie angeben."]}
    assert activity_texts(:oldest_first) == []
  end

  test "renames a category, logging only a real change" do
    kino = create!("Kino")

    {:ok, theater} = Categories.rename_category(nil, kino, %{name: "Theater"})
    {:ok, _same} = Categories.rename_category(nil, theater, %{name: "Theater "})

    assert Categories.get_category!(kino.id).name == "Theater"
    assert List.last(activity_texts(:oldest_first)) == "Kategorie „Kino“ umbenannt in „Theater“"
    assert length(activity_texts(:oldest_first)) == 2
  end

  describe "moving a category" do
    test "swaps it with its neighbour and logs it" do
      [first, second | _] = Categories.list_categories()

      {:ok, _moved} = Categories.move_category(nil, second, :up)
      assert Enum.take(names(), 2) == [second.name, first.name]
      {:ok, _moved} = Categories.move_category(nil, second, :down)
      assert Enum.take(names(), 2) == [first.name, second.name]

      assert activity_texts(:oldest_first) == [
               "Kategorie „Restaurant“ nach oben verschoben",
               "Kategorie „Restaurant“ nach unten verschoben"
             ]
    end

    test "does nothing at the edge" do
      first = hd(Categories.list_categories())

      assert {:ok, _same} = Categories.move_category(nil, first, :up)
      assert hd(names()) == first.name
      assert activity_texts(:oldest_first) == []
    end

    test "does not know an archived category" do
      second = Enum.at(Categories.list_categories(), 1)
      {:ok, archived} = Categories.archive_category(nil, second)

      assert Categories.move_category(nil, archived, :up) == {:error, :not_found}
    end
  end

  describe "creating a category after moves renumbered the positions" do
    test "puts it directly before Sonstiges" do
      {:ok, _moved} = Categories.move_category(nil, hd(Categories.list_categories()), :down)

      create!("Neu")

      assert Enum.take(names(), -3) == ["Geschenke", "Neu", "Sonstiges"]
    end

    test "still puts it directly before Sonstiges when that moved up by one" do
      create!("Neu")
      {:ok, _moved} = Categories.move_category(nil, List.last(Categories.list_categories()), :up)

      create!("Noch neuer")

      assert Enum.take(names(), -4) == ["Geschenke", "Noch neuer", "Sonstiges", "Neu"]
    end

    test "puts it at the end without an active Sonstiges" do
      {:ok, _archived} = Categories.archive_category(nil, List.last(Categories.list_categories()))

      create!("Zuletzt")

      assert List.last(names()) == "Zuletzt"
    end
  end

  test "archives and reactivates a category, logging both" do
    food = hd(Categories.list_categories())

    {:ok, archived} = Categories.archive_category(nil, food)
    assert Enum.map(Categories.list_categories(:archived), & &1.id) == [food.id]
    {:ok, _back} = Categories.reactivate_category(nil, archived)

    assert hd(names()) == "Lebensmittel"

    assert activity_texts(:oldest_first) == [
             "Kategorie „Lebensmittel“ archiviert",
             "Kategorie „Lebensmittel“ reaktiviert"
           ]
  end
end
