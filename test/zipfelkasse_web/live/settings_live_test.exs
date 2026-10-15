defmodule ZipfelkasseWeb.SettingsLiveTest do
  use ZipfelkasseWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Zipfelkasse.{Activities, Participants, Settings}

  setup %{conn: conn} do
    {:ok, anna} = Participants.join(%{name: "Anna"})
    %{anna: anna, conn: init_test_session(conn, participant_id: anna.id)}
  end

  defp save(view, name),
    do: view |> form("#settings-form", settings: %{group_name: name}) |> render_submit()

  defp renames,
    do: for(a <- Activities.list_activities(), a.details.text =~ "Gruppe", do: a.details.text)

  test "links the other settings with their plush", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    links =
      for link <-
            view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("#settings-links a") do
        {link |> LazyHTML.attribute("href") |> hd(), link |> LazyHTML.text() |> String.trim()}
      end

    assert links == [
             {"/settings/participants", "Teilnehmer"},
             {"/settings/categories", "Kategorien"},
             {"/settings/recurring", "Wiederkehrende Ausgaben"},
             {"/settings/rates", "Wechselkurse"},
             {"/settings/ynab", "YNAB"},
             {"/export", "Export"}
           ]

    for plush <- ~w(users tag repeat banknote wallet archive),
        do: assert(has_element?(view, ~s(#settings-links img[src^="/images/plush/#{plush}"])))
  end

  test "the colour scheme is chosen per browser", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(
             view,
             "section[aria-labelledby=settings-appearance] p",
             "Gilt nur für dieses Gerät."
           )

    assert has_element?(view, "#settings-theme[data-store=local]")
  end

  test "renames the group, logged only when the name changes", %{conn: conn, anna: anna} do
    {:ok, view, _html} = live(conn, ~p"/settings")
    assert has_element?(view, "#settings_group_name[value=Zipfelkasse]")

    save(view, "  WG   Süd ")

    assert_push_event(view, "setzkasten:saved", %{id: "settings-save"})
    assert Settings.group_name() == "WG Süd"
    assert has_element?(view, "#settings_group_name[value='WG Süd']")
    assert page_title(view) == "Einstellungen · WG Süd"

    save(view, "WG Süd")

    assert renames() == ["Gruppe umbenannt: „Zipfelkasse“ → „WG Süd“"]
    assert hd(Activities.list_activities()).actor_id == anna.id
  end

  test "an empty or long name stays in the field with its error", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    save(view, "  ")

    assert has_element?(
             view,
             "#settings_group_name-error-0",
             "Bitte einen Namen für die Gruppe angeben."
           )

    save(view, String.duplicate("y", 61))

    assert has_element?(
             view,
             "#settings_group_name-error-0",
             "Der Name ist zu lang (höchstens 60 Zeichen)."
           )

    assert Settings.group_name() == "Zipfelkasse"
    assert renames() == []
  end
end
