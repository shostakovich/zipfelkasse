defmodule ZipfelkasseWeb.ParticipantsLiveTest do
  use ZipfelkasseWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zipfelkasse.ActivityTexts
  import Zipfelkasse.Fixtures
  import ZipfelkasseWeb.PageText

  alias Zipfelkasse.Participants

  setup %{conn: conn} do
    h = household()
    %{h: h, conn: init_test_session(conn, participant_id: h.anna)}
  end

  defp add(view, name),
    do: view |> form("#participant-form", person: %{name: name}) |> render_submit()

  test "lists the people with their expenses and balance", %{conn: conn, h: h} do
    create!(equal(h, "Essen", 3000, "2026-10-01", h.anna, [h.anna, h.ben, h.cleo]))

    {:ok, view, _html} = live(conn, ~p"/settings/participants")

    assert page_title(view) == "Teilnehmer · Zipfelkasse"

    assert texts(view, "#participants > li .list-col-grow > p:first-of-type") ==
             ["Anna das bist du", "Ben", "Cleo"]

    assert texts(view, "#person-#{h.anna} .list-col-grow > p.truncate") ==
             ["1 Ausgabe · Saldo +20,00 €"]

    assert texts(view, "#person-#{h.ben} .list-col-grow > p.truncate") ==
             ["1 Ausgabe · Saldo −10,00 €"]

    assert has_element?(view, "#person-#{h.ben} data[value='-10.00'].text-error-ink")
    refute has_element?(view, "#participants-archived")
    assert has_element?(view, ~s(a[href="/settings"]), "Einstellungen")
  end

  test "adds a person, refusing a name taken regardless of case", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/participants")

    add(view, "  Dora   D. ")
    assert flash(view, :info) == "„Dora D.“ hinzugefügt."
    assert has_element?(view, "#person_name[phx-patch-focused]:not([value])")
    assert "Dora D." in texts(view, "#participants li p.font-medium")
    assert last_activity() == "Person „Dora D.“ hinzugefügt"

    add(view, " dora d. ")
    assert texts(view, "#person_name-error-0") == ["„dora d.“ gibt es schon."]
    assert has_element?(view, "#person_name[value='dora d.']")

    add(view, "")
    assert texts(view, "#person_name-error-0") == ["Bitte einen Namen für die Person angeben."]
  end

  test "renames in a popover at the row", %{conn: conn, h: h} do
    {:ok, view, _html} = live(conn, ~p"/settings/participants")

    view |> element("#person-#{h.cleo}-rename") |> render_click()

    assert has_element?(
             view,
             "#rename-#{h.cleo}[data-anchor=person-#{h.cleo}]",
             "„Cleo“ umbenennen"
           )

    assert has_element?(view, "#rename_name[value=Cleo]")

    view |> form("#rename-form", rename: %{name: "ben"}) |> render_submit()
    assert texts(view, "#rename_name-error-0") == ["„ben“ gibt es schon."]

    view |> form("#rename-form", rename: %{name: " Cleopatra "}) |> render_submit()
    assert flash(view, :info) == "Gespeichert."
    refute has_element?(view, "#rename-form")
    assert Participants.get_participant!(h.cleo).name == "Cleopatra"
    assert last_activity() == "Person „Cleo“ umbenannt in „Cleopatra“"
  end

  test "renaming oneself renames the reader in the header", %{conn: conn, h: h} do
    {:ok, view, _html} = live(conn, ~p"/settings/participants")

    view |> element("#person-#{h.anna}-rename") |> render_click()
    view |> form("#rename-form", rename: %{name: "Annika"}) |> render_submit()

    assert texts(view, "#current-participant") == ["Annika"]
  end

  test "archiving oneself goes to the choice of who one is", %{conn: conn, h: h} do
    {:ok, view, _html} = live(conn, ~p"/settings/participants")

    view |> element("#person-#{h.anna}-archive") |> render_click()

    assert {"/who", %{"info" => "„Anna“ archiviert."}} = assert_redirect(view)
  end

  test "closing the popover forgets the rename", %{conn: conn, h: h} do
    {:ok, view, _html} = live(conn, ~p"/settings/participants")

    view |> element("#person-#{h.cleo}-rename") |> render_click()
    render_hook(view, "cancel_rename", %{})

    refute has_element?(view, "#rename-form")
  end

  test "archives only a settled person and brings them back", %{conn: conn, h: h} do
    create!(equal(h, "Essen", 3000, "2026-10-01", h.anna, [h.anna, h.ben, h.cleo]))
    {:ok, dora} = Participants.create_participant(nil, %{name: "Dora"})

    {:ok, view, _html} = live(conn, ~p"/settings/participants")

    view |> element("#person-#{h.ben}-archive") |> render_click()

    assert flash(view, :error) ==
             "Ben hat noch einen Saldo von -10,00 €. Bitte erst ausgleichen, dann archivieren."

    view |> element("#person-#{dora.id}-archive") |> render_click()
    assert flash(view, :info) == "„Dora“ archiviert."
    assert texts(view, "#participants-archived") == ["Archiviert 1"]
    assert texts(view, "#participants-archived-list li") == ["Dora 0 Ausgaben Zurückholen"]

    view |> element("#person-#{dora.id}-reactivate") |> render_click()
    assert flash(view, :info) == "„Dora“ reaktiviert."
    refute has_element?(view, "#participants-archived")
    assert last_activity() == "Person „Dora“ reaktiviert"
  end
end
