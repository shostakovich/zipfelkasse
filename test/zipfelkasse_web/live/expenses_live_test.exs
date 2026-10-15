defmodule ZipfelkasseWeb.ExpensesLiveTest do
  use ZipfelkasseWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zipfelkasse.Fixtures
  import ZipfelkasseWeb.PageText

  alias Zipfelkasse.{LocalTime, Participants}

  setup %{conn: conn} do
    h = household()
    %{h: h, conn: init_test_session(conn, participant_id: h.anna)}
  end

  defp day(offset), do: LocalTime.today() |> Date.add(offset) |> Date.to_iso8601()
  defp shown(offset), do: LocalTime.today() |> Date.add(offset) |> Setzkasten.Format.date()

  defp row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#expenses > li[id^=expense-]")
    |> LazyHTML.attribute("id")
  end

  defp meta(view, expense), do: texts(view, "#expense-#{expense.id} .list-col-grow > p")

  defp headings(view), do: texts(view, "#expenses > li[id^=group-]")

  test "rows under period headings say who paid for whom and what it means for the reader",
       %{conn: conn, h: h} do
    soon = create!(equal(h, "Kino", 3000, day(3), h.anna, [h.anna, h.ben, h.cleo]))
    today = create!(equal(h, "Rewe", 1200, day(0), h.ben, [h.ben, h.cleo]))
    old = create!(equal(h, "Altes Zeug", 800, day(-800), h.cleo, [h.anna, h.cleo]))
    back = create!(reimbursement(500, day(0), h.ben, h.anna))

    {:ok, view, _html} = live(conn, ~p"/")

    assert headings(view) == ["Bevorstehend", "Diese Woche", "Älter"]
    assert row_ids(view) == Enum.map([soon, back, today, old], &"expense-#{&1.id}")

    assert meta(view, soon) ==
             ["Bezahlt von Anna für Anna, Ben, Cleo", "#{shown(3)} · Dein Saldo: +20,00 €"]

    assert text(view, "#expense-#{soon.id} .list-col-grow > a") == "Kino"

    assert meta(view, today) ==
             ["Bezahlt von Ben für Ben, Cleo", "#{shown(0)} · Du bist nicht beteiligt"]

    assert meta(view, old) ==
             ["Bezahlt von Cleo für Anna, Cleo", "#{shown(-800)} · Dein Saldo: −4,00 €"]

    assert meta(view, back) == ["Ben an Anna", "#{shown(0)} · Dein Saldo: −5,00 €"]

    assert has_element?(view, "#expense-#{back.id} img[src*='/images/plush/banknote']")
    assert has_element?(view, "#expense-#{soon.id} img[src*='/images/plush/shopping-cart']")
    assert has_element?(view, ~s(#expense-#{soon.id} a[href="/expenses/#{soon.id}"]))
  end

  test "an expense of all from four people on is for everybody", %{conn: conn, h: h} do
    {:ok, dora} = Participants.create_participant(nil, %{name: "Dora"})
    all = create!(equal(h, "WG-Party", 4000, day(0), h.anna, [h.anna, h.ben, h.cleo, dora.id]))
    three = create!(equal(h, "Pizza", 3000, day(0), h.anna, [h.anna, h.ben, h.cleo]))

    {:ok, view, _html} = live(conn, ~p"/")

    assert hd(meta(view, all)) == "Bezahlt von Anna für alle"
    assert hd(meta(view, three)) == "Bezahlt von Anna für Anna, Ben, Cleo"
  end

  test "the reader's balance links to the balances", %{conn: conn, h: h} do
    create!(equal(h, "Einkauf", 3000, day(0), h.anna, [h.anna, h.ben, h.cleo]))

    {:ok, view, _html} = live(conn, ~p"/")

    assert text(view, "#my-balance") =~ "Dein Saldo +20,00 € Du bekommst noch Geld."
    assert has_element?(view, ~s(#my-balance a[href="/balances"]))

    {:ok, ben_view, _html} = live(init_test_session(build_conn(), participant_id: h.ben), ~p"/")
    assert text(ben_view, "#my-balance") =~ "−10,00 € Du schuldest noch Geld."
  end

  test "a foreign amount shows its original below the euros", %{conn: conn, h: h} do
    yen = create!(foreign(h, "Ramen", 4850, "JPY", 160.0, day(0), h.anna, [h.anna]))

    {:ok, view, _html} = live(conn, ~p"/")

    column = text(view, "#expense-#{yen.id} .list-col-grow + div")
    assert column =~ "30,31 €"
    assert column =~ "4.850 JPY"
  end

  test "the search filters by text, category and person and can be reset", %{conn: conn, h: h} do
    rewe = create!(equal(h, "Rewe Einkauf", 1200, day(0), h.ben, [h.ben, h.cleo]))

    pizza =
      create!(
        Map.put(equal(h, "Pizza", 3000, day(-1), h.anna, [h.anna]), :category_id, h.restaurant)
      )

    noted =
      create!(Map.put(equal(h, "Markt", 900, day(-2), h.cleo, [h.cleo]), :notes, "Rewe-Ersatz"))

    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "a", "Filter zurücksetzen")

    view |> form("#expense-filter", %{"q" => " REWE "}) |> render_change()
    assert_patch(view, ~p"/?#{[q: "REWE"]}")
    assert row_ids(view) == ["expense-#{rewe.id}", "expense-#{noted.id}"]
    assert has_element?(view, "a", "Filter zurücksetzen")

    view
    |> form("#expense-filter", %{"q" => "", "category" => "#{h.restaurant}"})
    |> render_change()

    assert row_ids(view) == ["expense-#{pizza.id}"]

    view
    |> form("#expense-filter", %{"category" => "", "person" => "#{h.cleo}"})
    |> render_change()

    assert row_ids(view) == ["expense-#{rewe.id}", "expense-#{noted.id}"]

    view |> element("a", "Filter zurücksetzen") |> render_click()
    assert_patch(view, ~p"/")
    assert length(row_ids(view)) == 3

    {:ok, view, _html} = live(conn, ~p"/?#{[q: "nichts"]}")
    assert text(view, "main") =~ "Keine Ausgaben gefunden."
    assert has_element?(view, "main a[href='/']", "Filter zurücksetzen")
  end

  test "an archived category or person stays selectable while it is the filter", %{
    conn: conn,
    h: h
  } do
    {:ok, ben} =
      h.ben |> Participants.get_participant!() |> then(&Participants.archive_participant(nil, &1))

    {:ok, view, _html} = live(conn, ~p"/")
    refute has_element?(view, "#expense-filter option", "Ben")

    {:ok, view, _html} = live(conn, ~p"/?#{[person: ben.id]}")
    assert has_element?(view, "#expense-filter option[selected]", "Ben")
  end

  test "without expenses the list asks for the first one", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert text(view, "main") =~ "Noch keine Ausgaben."
    assert has_element?(view, ~s(main a[href="/expenses/new"]), "Erste Ausgabe anlegen")
    refute has_element?(view, "#expenses-more")
  end

  test "100 rows at a time, the next page continues the period without a new heading",
       %{conn: conn, h: h} do
    for n <- 1..101, do: create!(equal(h, "Posten #{n}", 100, day(0), h.anna, [h.anna]))

    {:ok, view, _html} = live(conn, ~p"/")
    assert length(row_ids(view)) == 100
    assert headings(view) == ["Diese Woche"]

    view |> element("#expenses-more") |> render_click()

    assert length(row_ids(view)) == 101
    assert headings(view) == ["Diese Woche"]
    refute has_element?(view, "#expenses-more")
  end

  test "an expense entered by someone else shows up at once", %{conn: conn, h: h} do
    {:ok, view, _html} = live(conn, ~p"/")

    expense = create!(equal(h, "Von Ben", 600, day(0), h.ben, [h.anna, h.ben]), h.ben)

    assert has_element?(view, "#expense-#{expense.id}", "Von Ben")
    assert text(view, "#my-balance") =~ "−3,00 €"
  end

  test "an expense of someone who joined meanwhile names them", %{conn: conn, h: h} do
    {:ok, view, _html} = live(conn, ~p"/")
    {:ok, dora} = Participants.create_participant(nil, %{name: "Dora"})

    expense =
      create!(equal(h, "Kuchen", 4000, day(0), dora.id, [h.anna, h.ben, h.cleo, dora.id]))

    assert hd(meta(view, expense)) == "Bezahlt von Dora für alle"
    assert has_element?(view, "#expense-filter select[name=person] option", "Dora")
  end
end
