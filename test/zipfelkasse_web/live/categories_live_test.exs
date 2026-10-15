defmodule ZipfelkasseWeb.CategoriesLiveTest do
  use ZipfelkasseWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zipfelkasse.ActivityTexts
  import Zipfelkasse.Fixtures
  import ZipfelkasseWeb.PageText

  alias Zipfelkasse.Categories

  @defaults [
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

  setup %{conn: conn} do
    h = household()
    %{h: h, conn: init_test_session(conn, participant_id: h.anna)}
  end

  defp names(view), do: texts(view, "#categories > li .list-col-grow > p.font-medium")

  test "lists the categories in their order with plush and number of expenses",
       %{conn: conn, h: h} do
    create!(equal(h, "Brot", 300, "2026-10-01", h.anna, [h.anna]))

    {:ok, view, _html} = live(conn, ~p"/settings/categories")

    assert page_title(view) == "Kategorien · Zipfelkasse"
    assert names(view) == @defaults
    assert texts(view, "#category-#{h.food} p.truncate") == ["1 Ausgabe"]
    assert texts(view, "#category-#{h.restaurant} p.truncate") == ["0 Ausgaben"]

    for {id, plush} <- [{h.food, "shopping-cart"}, {h.restaurant, "utensils"}],
        do: assert(has_element?(view, ~s(#category-#{id} img[src^="/images/plush/#{plush}"])))

    [first | _] = Categories.list_categories()
    last = List.last(Categories.list_categories())
    assert has_element?(view, "#category-#{first.id}-up[disabled]")
    refute has_element?(view, "#category-#{first.id}-down[disabled]")
    assert has_element?(view, "#category-#{last.id}-down[disabled]")
  end

  test "adds a category before Sonstiges", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/categories")

    view |> form("#category-form", category: %{name: " Haus  tiere "}) |> render_submit()

    assert flash(view, :info) == "Kategorie „Haus tiere“ hinzugefügt."
    assert has_element?(view, "#category_name[phx-patch-focused]:not([value])")
    assert view |> names() |> Enum.take(-3) == ["Geschenke", "Haus tiere", "Sonstiges"]

    view |> form("#category-form", category: %{name: "haus tiere"}) |> render_submit()
    assert texts(view, "#category_name-error-0") == ["Die Kategorie „haus tiere“ gibt es schon."]
  end

  test "moves up and down without a message", %{conn: conn, h: h} do
    {:ok, view, _html} = live(conn, ~p"/settings/categories")

    view |> element("#category-#{h.restaurant}-up") |> render_click()
    assert view |> names() |> Enum.take(2) == ["Restaurant", "Lebensmittel"]
    assert flash(view, :info) == nil

    view |> element("#category-#{h.restaurant}-down") |> render_click()
    view |> element("#category-#{h.restaurant}-down") |> render_click()
    assert view |> names() |> Enum.take(3) == ["Lebensmittel", "Haushalt", "Restaurant"]
    assert last_activity() == "Kategorie „Restaurant“ nach unten verschoben"
  end

  test "renames, archives and brings back", %{conn: conn, h: h} do
    {:ok, view, _html} = live(conn, ~p"/settings/categories")

    view |> element("#category-#{h.food}-rename-menu-item") |> render_click()
    view |> form("#rename-form", rename: %{name: "restaurant"}) |> render_submit()
    assert texts(view, "#rename_name-error-0") == ["Die Kategorie „restaurant“ gibt es schon."]

    view |> form("#rename-form", rename: %{name: "Essen & Trinken"}) |> render_submit()
    assert flash(view, :info) == "Gespeichert."
    assert view |> names() |> hd() == "Essen & Trinken"

    view |> element("#category-#{h.food}-archive-menu-item") |> render_click()
    assert flash(view, :info) == "Kategorie „Essen & Trinken“ archiviert."
    assert view |> names() |> hd() == "Restaurant"

    assert texts(view, "#categories-archived-list li") == [
             "Essen & Trinken 0 Ausgaben Zurückholen"
           ]

    view |> element("#category-#{h.food}-reactivate") |> render_click()
    assert flash(view, :info) == "Kategorie „Essen & Trinken“ reaktiviert."
    assert view |> names() |> hd() == "Essen & Trinken"
    refute has_element?(view, "#categories-archived")
  end
end
