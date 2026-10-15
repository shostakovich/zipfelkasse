defmodule Zipfelkasse.YnabTest do
  use Zipfelkasse.DataCase

  @moduletag :capture_log

  import Zipfelkasse.Fixtures

  alias Zipfelkasse.{Activities, Categories, FakeYnab, Ynab}
  alias Zipfelkasse.Ynab.{Connections, Run, Sync, Transactions}

  @target "plan-1|acc-geteilt"

  setup do
    %{fake: FakeYnab.start(), h: household()}
  end

  defp requests(fake), do: FakeYnab.take_requests(fake)
  defp connection(h), do: Connections.get(h.anna)
  defp last_activity, do: hd(Activities.list_activities(limit: 1)).details.text

  defp connect(h) do
    {:ok, "Token gespeichert."} = Ynab.save_token(h.anna, FakeYnab.token())
    {:ok, "Gespeichert."} = Ynab.choose_target(h.anna, @target, "2026-09-01")
  end

  test "a connection and a sync run never show their token when inspected", %{h: h} do
    connect(h)
    connection = connection(h)

    for term <- [connection, Run.new(connection, DateTime.utc_now())],
        do: refute(inspect(term) =~ FakeYnab.token())
  end

  describe "saving a token" do
    test "checks it before asking YNAB", %{h: h, fake: fake} do
      for token <- ["", "   "],
          do: assert(Ynab.save_token(h.anna, token) == {:error, "Bitte einen Token eingeben."})

      for token <- ["ab cd", "ab\tcd", String.duplicate("x", 201)],
          do:
            assert(
              Ynab.save_token(h.anna, token) ==
                {:error, "Das sieht nicht wie ein YNAB-Token aus."}
            )

      assert requests(fake) == []
    end

    test "refuses a token YNAB does not know and an unreachable YNAB", %{h: h, fake: fake} do
      assert Ynab.save_token(h.anna, "wrong") ==
               {:error, "YNAB kennt diesen Token nicht. Bitte prüfen und neu kopieren."}

      assert requests(fake) == ["GET /v1/plans"]

      FakeYnab.fail(fake, 503)

      assert Ynab.save_token(h.anna, "  #{FakeYnab.token()}  ") ==
               {:error, "YNAB ist gerade nicht erreichbar: YNAB-Fehler 503: Error 503 with •••"}

      assert connection(h) == nil
    end

    test "names a YNAB it cannot connect to", %{h: h} do
      Application.put_env(:zipfelkasse, Zipfelkasse.Ynab.Client,
        base_url: "http://127.0.0.1:9/v1"
      )

      assert Ynab.save_token(h.anna, FakeYnab.token()) ==
               {:error,
                "YNAB ist gerade nicht erreichbar: YNAB nicht erreichbar: keine Verbindung"}
    end

    test "saves a working token trimmed and logs the connection", %{h: h} do
      assert Ynab.save_token(h.anna, "  #{FakeYnab.token()}  ") == {:ok, "Token gespeichert."}

      assert %{
               token: "secret-token-123",
               plan_id: nil,
               account_id: nil,
               start_date: nil,
               token_invalid: false
             } =
               connection(h)

      assert last_activity() == "YNAB verbunden (Token gesetzt)"
      assert hd(Activities.list_activities(limit: 1)).actor_id == h.anna
    end

    test "resets plan and account when the new token cannot reach the plan", %{h: h} do
      connect(h)
      id = create!(equal(h, "Kino", 2400, "2026-09-20", h.anna, [h.anna, h.ben])).id
      Sync.sync_person(h.anna, false)

      assert Ynab.save_token(h.anna, FakeYnab.other_token()) ==
               {:ok,
                "Token gespeichert. Der bisher gewählte Plan ist mit diesem Token nicht erreichbar – " <>
                  "bitte Plan und Konto neu wählen."}

      assert {connection(h).plan_id, connection(h).account_id, connection(h).start_date} ==
               {nil, nil, ~D[2026-09-01]}

      assert [%{expense_id: ^id, ynab_transaction_id: nil, state: :retarget}] =
               Transactions.list(h.anna)

      assert last_activity() == "YNAB-Token ersetzt (Plan und Konto zurückgesetzt)"

      assert Ynab.save_token(h.anna, FakeYnab.token()) == {:ok, "Token gespeichert."}
      assert last_activity() == "YNAB-Token ersetzt"
    end

    test "disconnecting keeps plan, account and what is in YNAB", %{h: h} do
      connect(h)

      assert Ynab.disconnect(h.anna) ==
               {:ok, "YNAB-Verbindung getrennt. Die Buchungen in YNAB bleiben erhalten."}

      assert {connection(h).token, connection(h).plan_id, connection(h).account_id} ==
               {nil, "plan-1", "acc-geteilt"}

      assert last_activity() == "YNAB-Verbindung getrennt"

      assert Ynab.sync_now(h.anna) ==
               {:error,
                "YNAB ist noch nicht fertig eingerichtet (Token, Plan, Konto und Startdatum)."}
    end
  end

  describe "choosing plan and account" do
    test "needs a token, a valid start date and a usable account", %{h: h, fake: fake} do
      assert Ynab.choose_target(h.anna, @target, "2026-09-01") ==
               {:error, "Bitte zuerst einen Token eingeben."}

      {:ok, _message} = Ynab.save_token(h.anna, FakeYnab.token())
      requests(fake)

      for target <- [
            "plan-1|acc-depot",
            "plan-1|acc-alt",
            "plan-2|acc-geteilt",
            "plan-1",
            "",
            "plan-1|"
          ],
          do:
            assert(
              Ynab.choose_target(h.anna, target, "2026-09-01") ==
                {:error, "Bitte Plan und Konto auswählen."}
            )

      for start <- ["", "broken", "31.02.2026", "1999-12-31", "2026-13-01"],
          do:
            assert(
              Ynab.choose_target(h.anna, @target, start) ==
                {:error, "Bitte ein gültiges Startdatum angeben."}
            )

      assert requests(fake) == []

      assert {connection(h).plan_id, connection(h).account_id, connection(h).start_date} ==
               {nil, nil, nil}
    end

    test "saves the target and logs it with names, and changes of the start date", %{h: h} do
      {:ok, _message} = Ynab.save_token(h.anna, FakeYnab.token())

      assert Ynab.choose_target(h.anna, @target, "01.09.2026") == {:ok, "Gespeichert."}

      assert %{
               plan_id: "plan-1",
               account_id: "acc-geteilt",
               start_date: ~D[2026-09-01],
               connected_at: %DateTime{}
             } = connection(h)

      assert last_activity() ==
               "YNAB: Konto „Geteilt“ im Plan „Haushalt“ gewählt, Startdatum 01.09.2026"

      connected_at = connection(h).connected_at
      {:ok, _message} = Ynab.choose_target(h.anna, @target, "2026-08-01")
      assert last_activity() == "YNAB: Startdatum 01.09.2026 → 01.08.2026"
      assert connection(h).connected_at == connected_at
    end

    test "reports an unreachable YNAB, which is not cached", %{h: h, fake: fake} do
      {:ok, false} = Connections.put_token(h.anna, FakeYnab.token())
      FakeYnab.fail(fake, 503)

      assert Ynab.choose_target(h.anna, @target, "2026-09-01") ==
               {:error, "YNAB ist gerade nicht erreichbar: YNAB-Fehler 503: Error 503 with •••"}

      assert Ynab.choose_target(h.anna, @target, "2026-09-01") == {:ok, "Gespeichert."}
      requests(fake)
      assert Ynab.choose_target(h.anna, @target, "2026-09-02") == {:ok, "Gespeichert."}
      assert requests(fake) == []
    end
  end

  describe "mapping categories" do
    test "needs a target and known YNAB categories", %{h: h, fake: fake} do
      assert Ynab.map_categories(h.anna, %{h.food => "c-food"}) ==
               {:error, "Bitte zuerst Token, Plan und Konto einrichten."}

      connect(h)

      for category <- ["c-unknown", "c-old", "c-rta", "c-visa"],
          do:
            assert(
              Ynab.map_categories(h.anna, %{h.food => category}) ==
                {:error, "Unbekannte YNAB-Kategorie. Bitte die Seite neu laden."}
            )

      assert Ynab.map_categories(h.anna, %{999 => "c-food"}) == {:error, "Unbekannte Kategorie."}
      assert Connections.category_mapping(h.anna) == %{}
      assert "GET /v1/plans/plan-1/categories" in requests(fake)
    end

    test "saves the mapping and logs what changed", %{h: h} do
      connect(h)

      assert Ynab.map_categories(h.anna, %{
               Integer.to_string(h.food) => "c-food",
               h.restaurant => "c-out",
               "x" => "c-rent"
             }) == {:ok, "Kategorie-Zuordnung gespeichert."}

      assert Connections.category_mapping(h.anna) == %{
               h.food => "c-food",
               h.restaurant => "c-out"
             }

      assert last_activity() ==
               "YNAB: Kategorie-Zuordnung geändert (Lebensmittel → Lebensmittel & Drogerie, Restaurant → Essen gehen)"

      {:ok, _message} = Ynab.map_categories(h.anna, %{h.food => "", h.restaurant => "c-out"})

      assert last_activity() =~
               "(Lebensmittel → unkategorisiert (vorher Lebensmittel & Drogerie))"
    end
  end

  describe "the overview of the YNAB page" do
    test "without a connection", %{h: h, fake: fake} do
      overview = Ynab.overview(h.anna, now: ~U[2026-10-03 10:00:00Z])

      assert %{
               token_set: false,
               token_invalid: false,
               api_error: nil,
               plans: [],
               has_target: false,
               ready: false
             } =
               overview

      assert overview.start_date == ~D[2026-10-03]
      assert requests(fake) == []
    end

    test "lists the usable accounts and YNAB categories and every active category", %{h: h} do
      connect(h)
      {:ok, _message} = Ynab.map_categories(h.anna, %{h.food => "c-food"})
      {:ok, _archived} = Categories.archive_category(nil, Categories.get_category!(h.restaurant))

      overview = Ynab.overview(h.anna)

      assert overview.plans == [
               %{
                 name: "Haushalt",
                 accounts: [
                   %{value: "plan-1|acc-geteilt", name: "Geteilt", selected: true},
                   %{value: "plan-1|acc-giro", name: "Girokonto", selected: false}
                 ]
               }
             ]

      assert Enum.map(overview.groups, &{&1.name, Enum.map(&1.categories, fn c -> c.id end)}) ==
               [{"Alltag", ["c-food", "c-out"]}, {"Wohnen & <Freizeit>", ["c-rent", "c-fun"]}]

      assert [%{name: "Lebensmittel", selected: "c-food", missing: false} | rest] =
               overview.categories

      assert Enum.map(rest, &{&1.name, &1.selected}) == [
               {"Haushalt", nil},
               {"Miete & Nebenkosten", nil},
               {"Transport", nil},
               {"Reisen", nil},
               {"Freizeit", nil},
               {"Gesundheit", nil},
               {"Geschenke", nil},
               {"Sonstiges", nil}
             ]

      assert %{
               ready: true,
               currency: nil,
               start_date: ~D[2026-09-01],
               synced: 0,
               problems: [],
               balance: 0
             } = overview
    end

    test "names the error when YNAB is unreachable and shows an invalid token", %{
      h: h,
      fake: fake
    } do
      connect(h)
      FakeYnab.fail(fake, 503)

      assert Ynab.overview(h.anna, refresh: true).api_error ==
               "YNAB ist gerade nicht erreichbar: YNAB-Fehler 503: Error 503 with •••"

      FakeYnab.fail(fake, 401)
      create!(equal(h, "Kino", 2400, "2026-09-20", h.anna, [h.anna, h.ben]))
      Sync.sync_person(h.anna, false)
      requests(fake)

      assert %{token_invalid: true, plans: [], api_error: nil} = Ynab.overview(h.anna)
      assert requests(fake) == []

      assert connection(h).error ==
               "Der YNAB-Token ist ungültig oder abgelaufen. Bitte einen neuen Token eintragen."
    end
  end
end
