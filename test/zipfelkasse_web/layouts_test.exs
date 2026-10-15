defmodule ZipfelkasseWeb.LayoutsTest do
  use ZipfelkasseWeb.ConnCase

  import Phoenix.LiveViewTest

  @nav ~s(header nav[aria-label="Hauptnavigation"])

  setup %{conn: conn} do
    {:ok, anna} = Zipfelkasse.Participants.join(%{name: "Anna"})
    %{conn: init_test_session(conn, participant_id: anna.id)}
  end

  defp document(view), do: view |> render() |> LazyHTML.from_document()

  test "the shell links the four sections and marks the open one", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/balances")

    links =
      for link <- view |> document() |> LazyHTML.query(@nav <> " a") do
        {link |> LazyHTML.attribute("href") |> hd(), link |> LazyHTML.text() |> String.trim()}
      end

    assert links == [
             {"/", "Ausgaben"},
             {"/balances", "Salden"},
             {"/activity", "Aktivität"},
             {"/settings", "Einstellungen"}
           ]

    assert has_element?(view, ~s(#{@nav} a[href="/balances"][aria-current=page]))
    refute has_element?(view, ~s(#{@nav} a[href="/"][aria-current]))
  end

  test "the sections show their plush, the bar who is using the app", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/activity")

    for plush <- ~w(receipt scale activity settings) do
      assert has_element?(view, ~s(#{@nav} img[src^="/images/plush/#{plush}"]))
    end

    assert has_element?(view, "header #current-participant", "Anna")
    assert has_element?(view, ~s(header a[href="/who"]), "wechseln")
    assert page_title(view) == "Aktivität · Zipfelkasse"
  end

  test "every page has the brand, the floating button and one confirmation dialog", ctx do
    for path <- [~p"/", ~p"/expenses/new", ~p"/balances", ~p"/activity", ~p"/settings"] do
      {:ok, view, _html} = live(ctx.conn, path)

      assert has_element?(view, ~s(header a[href="/"]), "Zipfelkasse")

      assert has_element?(view, ~s(a[href="/expenses/new"][aria-label="Ausgabe hinzufügen"])) ==
               (path != ~p"/expenses/new")

      assert view |> document() |> LazyHTML.query("dialog#confirm-delete") |> Enum.count() == 1
    end
  end
end
