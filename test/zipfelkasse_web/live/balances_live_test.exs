defmodule ZipfelkasseWeb.BalancesLiveTest do
  use ZipfelkasseWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zipfelkasse.Fixtures
  import ZipfelkasseWeb.PageText

  alias Zipfelkasse.Participants

  setup %{conn: conn} do
    h = household()
    %{h: h, conn: init_test_session(conn, participant_id: h.anna)}
  end

  defp bar(view, id) do
    rect = view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("#balance-#{id} rect")

    case {LazyHTML.attribute(rect, "x"), LazyHTML.attribute(rect, "width")} do
      {[x], [width]} -> {x, width, rect |> LazyHTML.attribute("class") |> hd()}
      {[], []} -> nil
    end
  end

  test "bars to either side of zero, as wide as the balance", %{conn: conn, h: h} do
    {:ok, dora} = Participants.create_participant(nil, %{name: "Dora"})
    {:ok, emil} = Participants.create_participant(nil, %{name: "Emil"})
    {:ok, _emil} = Participants.archive_participant(nil, emil)
    create!(equal(h, "Essen", 3000, "2026-10-01", h.anna, [h.anna, h.ben, h.cleo]))
    create!(equal(h, "Kaugummi", 1, "2026-10-01", dora.id, [h.cleo]))

    {:ok, view, _html} = live(conn, ~p"/balances")

    assert text(view, "#balance-#{h.anna}") == "Anna +20,00 €"
    assert text(view, "#balance-#{h.cleo}") == "Cleo −10,01 €"
    assert text(view, "#balance-#{dora.id}") == "Dora +0,01 €"
    refute has_element?(view, "#balance-#{emil.id}")

    assert {"100", "100", "fill-chart-3-fill stroke-chart-3"} = bar(view, h.anna)
    assert {"50", "50", "fill-chart-4-fill stroke-chart-4"} = bar(view, h.ben)
    assert {"100", "1", _class} = bar(view, dora.id)

    summary =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#balance-chart [role=img]")
      |> LazyHTML.attribute("aria-label")

    assert Enum.map(summary, &squish/1) ==
             ["Salden: Anna +20,00 €, Ben −10,00 €, Cleo −10,01 €, Dora +0,01 €"]
  end

  test "the suggested transfers open the reimbursement prefilled", %{conn: conn, h: h} do
    create!(equal(h, "Essen", 3000, "2026-10-01", h.anna, [h.anna, h.ben, h.cleo]))

    {:ok, view, _html} = live(conn, ~p"/balances")

    assert text(view, "#transfer-0") =~ "Ben schuldet Anna 10,00 € Als erstattet markieren"
    assert text(view, "#transfer-1") =~ "Cleo schuldet Anna 10,00 €"

    {:ok, form, _html} =
      view |> element("#transfer-0-settle") |> render_click() |> follow_redirect(conn)

    assert has_element?(form, "#expense_reimbursement[checked]")
    assert has_element?(form, "#expense_amount[value='10,00']")
    assert has_element?(form, "#expense_paid_by_id option[selected][value='#{h.ben}']")
  end

  test "without open balances nobody needs to pay anything back", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/balances")

    assert text(view, "main") =~ "Alles ausgeglichen – niemand muss etwas zurückzahlen."
    refute has_element?(view, "#transfer-list")
    assert bar(view, 1) == nil
  end

  test "a new expense updates the balances", %{conn: conn, h: h} do
    {:ok, view, _html} = live(conn, ~p"/balances")

    create!(equal(h, "Essen", 600, "2026-10-01", h.ben, [h.anna, h.ben]))

    assert text(view, "#balance-#{h.ben}") == "Ben +3,00 €"
  end
end
