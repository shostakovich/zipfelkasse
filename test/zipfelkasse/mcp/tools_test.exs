defmodule Zipfelkasse.MCP.ToolsTest do
  use Zipfelkasse.DataCase

  @moduletag :capture_log

  alias Zipfelkasse.{Activities, Categories, Expenses, Participants}
  alias Zipfelkasse.Fx.Rate
  alias Zipfelkasse.MCP.Tools

  @today ~D[2026-10-03]
  @usd_sept_30 1.1261
  @usd_oct_2 1.1236
  @categories "Lebensmittel, Restaurant, Haushalt, Miete & Nebenkosten, Transport, Reisen, Freizeit, " <>
                "Gesundheit, Geschenke, Sonstiges"
  @all_people "Available: Anna, Ben, Cleo, Dora, Emil."
  @active_people "Available: Anna, Ben, Cleo, Dora."
  @unknown_category ~s(Unknown category "Yacht". Available: #{@categories}.)
  @rule "expected digits with at most 2 decimal places after a dot and no thousands separator"

  setup do
    {:ok, anna} = Participants.join(%{name: "Anna"})

    [ben, cleo, dora, emil] =
      for name <- ~w(Ben Cleo Dora Emil) do
        {:ok, person} = Participants.create_participant(anna.id, %{name: name})
        person
      end

    {:ok, _emil} = Participants.archive_participant(anna.id, emil)
    health = Enum.find(Categories.list_categories(), &(&1.name == "Gesundheit"))
    {:ok, _health} = Categories.archive_category(anna.id, health)

    for {date, rate} <- [{~D[2026-09-30], @usd_sept_30}, {~D[2026-10-02], @usd_oct_2}],
        do: Repo.insert!(%Rate{currency: "USD", source: :ecb, date: date, rate: rate})

    %{anna: anna.id, ben: ben.id, cleo: cleo.id, dora: dora.id, emil: emil.id}
  end

  defp call(name, arguments) do
    arguments = if is_binary(arguments), do: JSON.decode!(arguments), else: arguments
    Tools.call(name, arguments, today: @today)
  end

  defp ok(name, arguments \\ %{}) do
    {text, error?} = call(name, arguments)
    refute error?, "#{name} #{inspect(arguments)}: #{text}"
    JSON.decode!(text)
  end

  defp refusal(name, arguments) do
    {text, error?} = call(name, arguments)
    assert error?, "#{name} #{inspect(arguments)}: expected a refusal, got #{text}"
    text
  end

  defp decode_refusal(name, arguments, field) do
    message = refusal(name, arguments)
    assert message =~ "Invalid arguments"
    assert message =~ field
  end

  defp eur(cents),
    do:
      if(cents < 0, do: "-", else: "") <>
        "#{div(abs(cents), 100)}." <> String.pad_leading("#{rem(abs(cents), 100)}", 2, "0")

  defp balance_rows(key, list, names) do
    for {period, cents} <- list do
      %{
        key => period,
        "balances" =>
          Enum.zip_with(names, cents, fn name, c ->
            %{"person" => name, "balance" => eur(c), "balance_cents" => c}
          end)
      }
    end
  end

  # The entries of the household, all made through the tools.
  defp entries do
    ok(
      "create_expense",
      ~s({"title":" Rewe ","amount":"30","paid_by":"anna","date":"2026-09-15","category":"lebensmittel","participants":["Anna","ben","CLEO"]})
    )

    ok(
      "create_expense",
      ~s({"title":"Pizza & Wein","amount":40,"paid_by":"Ben","date":"2026-09-20","category":"Restaurant","split":"shares","weights":{"Anna":1,"Ben":"3"}})
    )

    ok(
      "create_expense",
      ~s({"title":"Kino <3D>","amount":"25.00","paid_by":"Cleo","date":"10.09.2025","split":"percent","weights":{"Anna":"50","Cleo":50},"notes":"Zeile 1\\nZeile \\"2\\""})
    )

    ok(
      "create_expense",
      ~s({"title":"Hotel","amount":"100","currency":"usd","paid_by":"Dora","date":"2026-09-30","category":"Reisen"})
    )

    ok(
      "create_expense",
      ~s({"title":"Sushi","amount":2000,"currency":"JPY","fx_rate":160,"paid_by":"Anna","date":"2026-10-01","split":"amount","weights":{"Anna":"1200","Ben":800}})
    )

    ok(
      "create_reimbursement",
      ~s({"from":"Ben","to":"anna","amount":"15","date":"2026-10-02","notes":"PayPal"})
    )

    ok("create_expense", ~s({"title":"Taxi","amount":"10","currency":"USD","paid_by":"Ben"}))
    Expenses.list_expenses([reimbursement: nil], sort: :date_asc) |> Map.new(&{&1.title, &1.id})
  end

  test "people and categories come from the app" do
    assert Enum.map(ok("balances")["balances"], & &1["person"]) == ~w(Anna Ben Cleo Dora)

    assert refusal("search_expenses", %{"person" => "Zoe"}) ==
             ~s(Unknown person "Zoe". #{@all_people})

    assert refusal("statistics", %{"group_by" => "month", "category" => "Yacht"}) ==
             @unknown_category
  end

  test "create_expense: every refusal" do
    x = ~s("title":"X","amount":"10","paid_by":"Anna")
    jpy = ~s("title":"X","amount":"1000","currency":"JPY","fx_rate":160,"paid_by":"Anna")

    for {args, message} <- [
          {~s({"amount":"10","paid_by":"Anna"}), "Parameter title is missing."},
          {~s({"title":"  ","amount":"10","paid_by":"Anna"}), "Parameter title is missing."},
          {~s({#{x},"date":"morgen"}),
           ~s|Invalid date for date: "morgen" (expected YYYY-MM-DD).|},
          {~s({#{x},"date":"2026-02-30"}),
           ~s|Invalid date for date: "2026-02-30" (expected YYYY-MM-DD).|},
          {~s({#{x},"date":"1999-12-31"}),
           ~s|Invalid date for date: "1999-12-31" (expected YYYY-MM-DD).|},
          {~s({#{x},"currency":"EURO"}),
           ~s(currency must be a three-letter ISO code such as USD, not "EURO".)},
          {~s({#{x},"currency":"U1D"}),
           ~s(currency must be a three-letter ISO code such as USD, not "U1D".)},
          {~s({"title":"X","paid_by":"Anna"}), "Parameter amount is missing."},
          {~s({"title":"X","amount":" ","paid_by":"Anna"}), "Parameter amount is missing."},
          {~s({"title":"X","amount":"1.234","paid_by":"Anna"}),
           ~s(Invalid amount "1.234" for EUR: #{@rule}.)},
          {~s({"title":"X","amount":"1,5","paid_by":"Anna"}),
           ~s(Invalid amount "1,5" for EUR: #{@rule}.)},
          {~s({"title":"X","amount":"-5","paid_by":"Anna"}),
           ~s(Invalid amount "-5" for EUR: #{@rule}.)},
          {~s({"title":"X","amount":"10 €","paid_by":"Anna"}),
           ~s(Invalid amount "10 €" for EUR: #{@rule}.)},
          {~s({"title":"X","amount":"1.5","currency":"JPY","paid_by":"Anna"}),
           ~s(Invalid amount "1.5" for JPY: expected digits with at most 0 decimal places after a dot and no thousands separator.)},
          {~s({"title":"X","amount":"1.2345","currency":"kwd","paid_by":"Anna"}),
           ~s(Invalid amount "1.2345" for KWD: expected digits with at most 3 decimal places after a dot and no thousands separator.)},
          {~s({"title":"X","amount":"0","paid_by":"Anna"}),
           "The app refused the entry (message in German): Der Betrag muss größer als 0 sein."},
          {~s({"title":"X","amount":0,"paid_by":"Anna"}),
           "The app refused the entry (message in German): Der Betrag muss größer als 0 sein."},
          {~s({#{x},"fx_rate":1.1}), "fx_rate is only for foreign currencies."},
          {~s({#{x},"currency":"eur","fx_rate":1}), "fx_rate is only for foreign currencies."},
          {~s({#{x},"currency":"USD","fx_rate":0}),
           "The app refused the entry (message in German): Bitte einen Wechselkurs für USD angeben."},
          {~s({#{x},"currency":"XAF"}),
           "There is no exchange rate for XAF on 2026-10-03. Ask the user for the rate and pass it as fx_rate."},
          {~s({#{x},"currency":"USD","date":"2023-06-01"}),
           "There is no exchange rate for USD on 2023-06-01. Ask the user for the rate and pass it as fx_rate."},
          {~s({"title":"X","amount":"10"}), "Parameter paid_by is missing."},
          {~s({"title":"X","amount":"10","paid_by":"Zoe"}),
           ~s(Unknown person "Zoe" in paid_by. #{@active_people})},
          {~s({"title":"X","amount":"10","paid_by":"emil"}),
           "Emil is archived and cannot take part in new entries."},
          {~s({#{x},"category":"Yacht"}), @unknown_category},
          {~s({#{x},"category":"gesundheit"}), "Category Gesundheit is archived."},
          {~s({#{x},"weights":{"Anna":1}}),
           "weights are only for split=shares, percent or amount; use participants for an equal split."},
          {~s({#{x},"split":"shares"}), "split=shares needs weights (person name → value)."},
          {~s({#{x},"split":"percent","participants":["Anna"],"weights":{"Anna":100}}),
           "With split=percent, weights name the participants; leave participants out."},
          {~s({#{x},"participants":["Anna","anna"]}), "Anna appears twice in the split."},
          {~s({#{x},"participants":["Anna","Zoe"]}),
           ~s(Unknown person "Zoe" in the split. #{@active_people})},
          {~s({#{x},"split":"shares","weights":{"Anna":"1.5","Ben":1}}),
           ~s(Invalid value "1.5" for Anna in weights: expected digits with at most 0 decimal places after a dot and no thousands separator.)},
          {~s({#{x},"split":"shares","weights":{"Zoe":1,"Anna":"x"}}),
           ~s(Invalid value "x" for Anna in weights: expected digits with at most 0 decimal places after a dot and no thousands separator.)},
          {~s({#{x},"split":"shares","weights":{"ben":1,"Anna":1,"Zoe":1}}),
           ~s(Unknown person "Zoe" in the split. #{@active_people})},
          {~s({#{x},"split":"shares","weights":{"anna":2,"Anna":1}}),
           "Anna appears twice in the split."},
          {~s({#{jpy},"split":"amount","weights":{"Anna":"500.5","Ben":500}}),
           ~s(Invalid value "500.5" for Anna in weights: expected digits with at most 0 decimal places after a dot and no thousands separator.)},
          {~s({#{x},"split":"percent","weights":{"Anna":60,"Ben":"30"}}),
           "The app refused the entry (message in German): Die Prozente müssen zusammen 100 % ergeben (aktuell 90,00 %)."},
          {~s({#{x},"split":"amount","weights":{"Anna":"5","Ben":"4"}}),
           "The app refused the entry (message in German): Die Beträge müssen zusammen 10,00 € ergeben (aktuell 9,00 €)."},
          {~s|{"title":"#{String.duplicate("t", 201)}","amount":"1","paid_by":"Anna"}|,
           "The app refused the entry (message in German): Der Titel ist zu lang (höchstens 200 Zeichen)."},
          {~s({"amount":"x","paid_by":"Zoe","date":"x"}), "Parameter title is missing."},
          {~s({"title":"X","amount":"x","paid_by":"Zoe","date":"x"}),
           ~s|Invalid date for date: "x" (expected YYYY-MM-DD).|},
          {~s({"title":"X","amount":"x","paid_by":"Zoe","category":"Yacht"}),
           ~s(Invalid amount "x" for EUR: #{@rule}.)},
          {~s({"title":"X","amount":"1","paid_by":"Zoe","category":"Yacht"}),
           ~s(Unknown person "Zoe" in paid_by. #{@active_people})},
          {~s({"title":"X","amount":"1","paid_by":"Anna","category":"Yacht","participants":["Zoe"]}),
           @unknown_category}
        ] do
      assert refusal("create_expense", args) == message
    end

    for {args, field} <- [
          {~s({#{x},"split":"random"}), "split"},
          {~s({"title":"X","amount":true,"paid_by":"Anna"}), "amount"},
          {~s({#{x},"split":"shares","weights":{"Anna":true}}), "weights"},
          {~s({#{x},"titel":"Y"}), "titel"},
          {~s({"title":5,"amount":"10","paid_by":"Anna"}), "title"},
          {~s({#{x},"participants":"Anna"}), "participants"},
          {~s({#{x},"allow_duplicate":"yes"}), "allow_duplicate"},
          {~s({#{x},"currency":"USD","fx_rate":"1.2"}), "fx_rate"},
          {~s({#{x},"weights":["Anna"]}), "weights"}
        ],
        do: decode_refusal("create_expense", args, field)

    assert Expenses.list_expenses() == []
  end

  test "create_reimbursement: every refusal" do
    for {args, message} <- [
          {~s({"to":"Anna","amount":"5"}), "Parameter from is missing."},
          {~s({"from":"Ben","amount":"5"}), "Parameter to is missing."},
          {~s({"from":"Ben","to":"Anna"}), "Parameter amount is missing."},
          {~s({"from":"Zoe","to":"Anna","amount":"5"}),
           ~s(Unknown person "Zoe" in from. #{@active_people})},
          {~s({"from":"emil","to":"Anna","amount":"5"}),
           "Emil is archived and cannot take part in new entries."},
          {~s({"from":"ben","to":" Ben ","amount":"5"}),
           "The app refused the entry (message in German): Bei einer Rückzahlung müssen Zahler und Empfänger verschieden sein."},
          {~s({"from":"Ben","to":"Anna","amount":"5","date":"31.02.2026"}),
           ~s|Invalid date for date: "31.02.2026" (expected YYYY-MM-DD).|},
          {~s({"from":"Ben","to":"Anna","amount":"5","fx_rate":2}),
           "fx_rate is only for foreign currencies."},
          {~s|{"from":"Ben","to":"Anna","amount":"5","notes":"#{String.duplicate("n", 2001)}"}|,
           "The app refused the entry (message in German): Die Notiz ist zu lang (höchstens 2000 Zeichen)."},
          {~s({"from":"Zoe","to":"Zoe","amount":"x"}), ~s(Invalid amount "x" for EUR: #{@rule}.)}
        ] do
      assert refusal("create_reimbursement", args) == message
    end

    decode_refusal(
      "create_reimbursement",
      ~s({"from":"Ben","to":"Anna","amount":"5","title":"Rückzahlung"}),
      "title"
    )

    decode_refusal("create_reimbursement", ~s({"from":["Ben"],"to":"Anna","amount":"5"}), "from")
    assert Expenses.list_expenses(reimbursement: nil) == []
  end

  test "create_expense and create_reimbursement store ordinary entries with the payer as author",
       people do
    ids = entries()

    created =
      &ok("search_expenses", %{"detail" => "full", "reimbursements" => "include", "text" => &1})[
        "expenses"
      ]

    assert created.("rewe") == [
             %{
               "id" => ids["Rewe"],
               "date" => "2026-09-15",
               "title" => "Rewe",
               "category" => "Lebensmittel",
               "paid_by" => "Anna",
               "amount" => "30.00",
               "amount_cents" => 3000,
               "split" => "equal",
               "shares" => [
                 %{"person" => "Anna", "amount" => "10.00", "amount_cents" => 1000},
                 %{"person" => "Ben", "amount" => "10.00", "amount_cents" => 1000},
                 %{"person" => "Cleo", "amount" => "10.00", "amount_cents" => 1000}
               ]
             }
           ]

    assert [%{"notes" => ~s(Zeile 1\nZeile "2"), "split" => "percent", "title" => "Kino <3D>"}] =
             created.("kino")

    assert [
             %{
               "amount_cents" => 8880,
               "original" => "100.00 USD",
               "fx_rate" => @usd_sept_30,
               "fx_source" => "ecb",
               "shares" => hotel
             }
           ] =
             created.("Hotel")

    assert Enum.map(hotel, & &1["amount_cents"]) == [2220, 2220, 2220, 2220]

    assert [
             %{
               "amount" => "12.50",
               "original" => "2000 JPY",
               "fx_rate" => 160.0,
               "fx_source" => "manual",
               "shares" => sushi
             }
           ] =
             created.("Sushi")

    assert Enum.map(sushi, &{&1["person"], &1["amount_cents"]}) == [{"Anna", 750}, {"Ben", 500}]

    assert created.("Rückzahlung") == [
             %{
               "id" => ids["Rückzahlung"],
               "date" => "2026-10-02",
               "title" => "Rückzahlung",
               "paid_by" => "Ben",
               "amount" => "15.00",
               "amount_cents" => 1500,
               "reimbursement" => true,
               "recipient" => "Anna",
               "notes" => "PayPal"
             }
           ]

    assert [
             %{
               "date" => "2026-10-03",
               "amount_cents" => 890,
               "fx_rate" => @usd_oct_2,
               "shares" => taxi
             }
           ] = created.("Taxi")

    assert taxi |> Enum.map(& &1["amount_cents"]) |> Enum.sort() == [222, 222, 223, 223]

    assert String.ends_with?(
             Zipfelkasse.MCP.instructions(),
             "\nData overview: 6 expenses and 1 reimbursements dated 2025-09-10 to 2026-10-03. 3 of the " <>
               "expenses (50.0%) have no category. Values of activities.action: expense_created, settings_updated."
           )

    [newest | _] = Activities.list_activities(limit: 1)

    assert {newest.action, newest.actor_id, newest.expense_id, newest.details.text} ==
             {:expense_created, people.ben, ids["Taxi"], "Über MCP angelegt"}

    {text, false} =
      call(
        "create_expense",
        ~s({"title":"Gartenmöbel","amount":"23.40","paid_by":"Cleo","date":"2026-09-01","split":"amount","weights":{"Anna":"15.00","Ben":8.40}})
      )

    assert %{"created" => %{"amount_cents" => 2340}, "note" => note} = JSON.decode!(text)
    assert note =~ "with Cleo as author. Changing or deleting it is only possible in the app."

    assert ok(
             "create_reimbursement",
             ~s({"from":"Dora","to":"Cleo","amount":"50","currency":"chf","fx_rate":0.9,"date":"2026-09-05"})
           )[
             "created"
           ]
           |> Map.take(~w(amount_cents original fx_rate fx_source recipient)) ==
             %{
               "amount_cents" => 5556,
               "original" => "50.00 CHF",
               "fx_rate" => 0.9,
               "fx_source" => "manual",
               "recipient" => "Cleo"
             }
  end

  test "refuses likely duplicates unless allowed" do
    ids = entries()

    dup = fn id, what ->
      "This looks like a duplicate of entry #{id} (#{what}). Ask the user; if it really is a second one, " <>
        "call again with allow_duplicate=true."
    end

    assert refusal(
             "create_expense",
             ~s({"title":"rewe","amount":"30.00","paid_by":"Anna","date":"2026-09-15"})
           ) ==
             dup.(ids["Rewe"], "2026-09-15, Rewe, 30.00 EUR, paid by Anna")

    assert refusal(
             "create_expense",
             ~s({"title":"  REWE ","amount":30,"paid_by":"anna","date":"15.09.2026","category":"Haushalt","participants":["Dora"]})
           ) ==
             dup.(ids["Rewe"], "2026-09-15, Rewe, 30.00 EUR, paid by Anna")

    assert refusal(
             "create_expense",
             ~s({"title":"Hotel","amount":"100","currency":"USD","paid_by":"Dora","date":"2026-09-30"})
           ) ==
             dup.(ids["Hotel"], "2026-09-30, Hotel, 88.80 EUR, paid by Dora")

    assert refusal(
             "create_expense",
             ~s({"title":"Taxi","amount":"10","currency":"usd","paid_by":"Ben"})
           ) ==
             dup.(ids["Taxi"], "2026-10-03, Taxi, 8.90 EUR, paid by Ben")

    assert refusal(
             "create_reimbursement",
             ~s({"from":"Ben","to":"Anna","amount":15,"date":"2026-10-02","notes":"nochmal"})
           ) ==
             dup.(ids["Rückzahlung"], "2026-10-02, Rückzahlung, 15.00 EUR, paid by Ben")

    ok(
      "create_expense",
      ~s({"title":"rewe","amount":"30.00","paid_by":"Anna","date":"2026-09-15","allow_duplicate":true})
    )

    ok("create_reimbursement", ~s({"from":"Ben","to":"Cleo","amount":"15","date":"2026-10-02"}))

    ok(
      "create_expense",
      ~s({"title":"Rückzahlung","amount":"15","paid_by":"Ben","date":"2026-10-02","participants":["Anna"]})
    )
  end

  # Objects as lists of {key, value} in the order of the text.
  defp ordered(name, arguments) do
    {text, false} = call(name, arguments)
    finish = fn pairs, acc -> {Enum.reverse(pairs), acc} end
    {term, :ok, ""} = :json.decode(text, :ok, %{object_finish: finish})
    term
  end

  defp keys(object), do: Enum.map(object, &elem(&1, 0))
  defp first_of(object, key), do: object |> List.keyfind!(key, 0) |> elem(1) |> hd()

  test "results list their keys in a readable order" do
    entries()

    balances = ordered("balances", %{})
    assert keys(balances) == ~w(balances settlements note)
    assert balances |> first_of("balances") |> keys() == ~w(person balance balance_cents status)
    assert balances |> first_of("settlements") |> keys() == ~w(from to amount amount_cents)

    history = ordered("balance_history", %{})
    assert keys(history) == ~w(interval period rows note)
    assert history |> first_of("rows") |> keys() == ~w(month balances)

    search = ordered("search_expenses", ~s({"text":"Hotel","person":"Anna","detail":"full"}))

    assert keys(search) ==
             ~w(matches shown truncated total total_cents expenses person_share)

    assert search |> first_of("expenses") |> keys() ==
             ~w(id date title category paid_by amount amount_cents original fx_rate fx_source split shares)

    assert search |> first_of("expenses") |> first_of("shares") |> keys() ==
             ~w(person amount amount_cents)

    statistics =
      ordered(
        "statistics",
        ~s({"group_by":"person","compare":"previous_year","from":"2026-01-01"})
      )

    assert keys(statistics) ==
             ~w(group_by perspective period rows rows_total truncated total total_cents previous_period
                previous_total previous_total_cents note)

    {"rows", rows} = List.keyfind!(statistics, "rows", 0)

    assert rows |> Enum.max_by(&length/1) |> keys() ==
             ~w(person count amount amount_cents paid paid_cents previous previous_cents change change_cents
                change_percent)

    activity = ordered("activity", ~s({"limit":1}))
    assert keys(activity) == ~w(entries shown more note)

    assert activity |> first_of("entries") |> keys() ==
             ~w(id at actor action expense_id title amount amount_cents text)

    assert keys(ordered("sql_query", ~s({"query":"SELECT 1"}))) ==
             ~w(columns rows row_count truncated)

    created = ordered("create_expense", ~s({"title":"Brot","amount":"3","paid_by":"Anna"}))
    assert keys(created) == ~w(created note)
  end

  test "balances and balance_history" do
    entries()

    assert ok("balances") == %{
             "balances" => [
               %{
                 "person" => "Anna",
                 "balance" => "-36.93",
                 "balance_cents" => -3693,
                 "status" => "owes money"
               },
               %{
                 "person" => "Ben",
                 "balance" => "-5.52",
                 "balance_cents" => -552,
                 "status" => "owes money"
               },
               %{
                 "person" => "Cleo",
                 "balance" => "-21.92",
                 "balance_cents" => -2192,
                 "status" => "owes money"
               },
               %{
                 "person" => "Dora",
                 "balance" => "64.37",
                 "balance_cents" => 6437,
                 "status" => "is owed money"
               }
             ],
             "note" =>
               "Positive balance = is owed money, negative = owes money. settlements: the transfers needed so that everyone ends at 0.",
             "settlements" => [
               %{"from" => "Anna", "to" => "Dora", "amount" => "36.93", "amount_cents" => 3693},
               %{"from" => "Cleo", "to" => "Dora", "amount" => "21.92", "amount_cents" => 2192},
               %{"from" => "Ben", "to" => "Dora", "amount" => "5.52", "amount_cents" => 552}
             ]
           }

    decode_refusal("balances", %{"x" => 1}, "x")
    abcd = ~w(Anna Ben Cleo Dora)
    history = ok("balance_history")
    assert {history["interval"], history["period"]} == {"month", "2025-09-10 to 2026-10-03"}
    months = Enum.map(history["rows"], & &1["month"])

    assert months ==
             ~w(2025-09 2025-10 2025-11 2025-12 2026-01 2026-02 2026-03 2026-04 2026-05 2026-06 2026-07 2026-08 2026-09 2026-10)

    assert history["rows"] ==
             balance_rows(
               "month",
               Enum.map(months, fn m ->
                 cond do
                   m < "2026-09" -> {m, [-1250, 0, 1250, 0]}
                   m == "2026-09" -> {m, [-2470, -2220, -1970, 6660]}
                   true -> {m, [-3693, -552, -2192, 6437]}
                 end
               end),
               abcd
             )

    to_sept = ok("balance_history", %{"to" => "2026-09-20"})
    assert {to_sept["period"], length(to_sept["rows"])} == {"2025-09-10 to 2026-09-20", 13}

    assert ok("balance_history", %{"interval" => "year", "person" => "cleo"})["rows"] ==
             balance_rows("year", [{"2025", [1250]}, {"2026", [-2192]}], ["Cleo"])

    weeks =
      ok("balance_history", %{"interval" => "week", "from" => "2026-09-14", "to" => "30.09.2026"})

    assert weeks["period"] == "2026-09-14 to 2026-09-30"

    assert weeks["rows"] ==
             balance_rows(
               "week",
               [
                 {"2026-W38", [-250, 0, 250, 0]},
                 {"2026-W39", [-250, 0, 250, 0]},
                 {"2026-W40", [-3693, -552, -2192, 6437]}
               ],
               abcd
             )

    assert ok("balance_history", %{
             "interval" => "year",
             "person" => "Emil",
             "from" => "2026-01-01"
           })["rows"] ==
             balance_rows("year", [{"2026", [0]}], ["Emil"])

    for {args, message} <- [
          {%{"person" => "Zoe"}, ~s(Unknown person "Zoe". #{@all_people})},
          {%{"interval" => "week", "from" => "2000-01-01"},
           "That is 1397 periods, at most 500 are possible. Please narrow down from/to or choose a longer interval."},
          {%{"from" => "1900-01-01"},
           ~s|Invalid date for from: "1900-01-01" (expected YYYY-MM-DD).|},
          {%{"from" => "2026-10-01", "to" => "2026-09-01"},
           ~s|"to" (2026-09-01) is before "from" (2026-10-01).|}
        ],
        do: assert(refusal("balance_history", args) == message)

    decode_refusal("balance_history", %{"interval" => "day"}, "interval")
  end

  test "search_expenses" do
    ids = entries()

    compact = %{
      "Rewe" => %{
        "date" => "2026-09-15",
        "category" => "Lebensmittel",
        "paid_by" => "Anna",
        "amount_cents" => 3000
      },
      "Pizza & Wein" => %{
        "date" => "2026-09-20",
        "category" => "Restaurant",
        "paid_by" => "Ben",
        "amount_cents" => 4000
      },
      "Kino <3D>" => %{"date" => "2025-09-10", "paid_by" => "Cleo", "amount_cents" => 2500},
      "Hotel" => %{
        "date" => "2026-09-30",
        "category" => "Reisen",
        "paid_by" => "Dora",
        "amount_cents" => 8880
      },
      "Sushi" => %{"date" => "2026-10-01", "paid_by" => "Anna", "amount_cents" => 1250},
      "Rückzahlung" => %{
        "date" => "2026-10-02",
        "paid_by" => "Ben",
        "amount_cents" => 1500,
        "reimbursement" => true,
        "recipient" => "Anna"
      },
      "Taxi" => %{"date" => "2026-10-03", "paid_by" => "Ben", "amount_cents" => 890}
    }

    expect = fn args, titles, matches, total, extra ->
      found = ok("search_expenses", args)

      expenses =
        for title <- titles do
          entry = compact[title]

          Map.merge(entry, %{
            "id" => ids[title],
            "title" => title,
            "amount" => eur(entry["amount_cents"])
          })
        end

      assert found ==
               Map.merge(
                 %{
                   "expenses" => expenses,
                   "matches" => matches,
                   "shown" => length(titles),
                   "total" => eur(total),
                   "total_cents" => total,
                   "truncated" => matches > length(titles)
                 },
                 extra
               ),
             inspect(args)
    end

    all = ["Taxi", "Sushi", "Hotel", "Pizza & Wein", "Rewe", "Kino <3D>"]
    expect.(%{}, all, 6, 20_520, %{})
    expect.(%{"limit" => 1}, ["Taxi"], 6, 20_520, %{})
    expect.(%{"reimbursements" => "only"}, ["Rückzahlung"], 1, 1500, %{})

    expect.(
      %{"reimbursements" => "include", "sort" => "date_asc"},
      ["Kino <3D>", "Rewe", "Pizza & Wein", "Hotel", "Sushi", "Rückzahlung", "Taxi"],
      7,
      22_020,
      %{}
    )

    expect.(%{"text" => "RÜCKZAHLUNG", "reimbursements" => "only"}, ["Rückzahlung"], 1, 1500, %{})
    expect.(%{"text" => "rückzahlung"}, [], 0, 0, %{})
    expect.(%{"text" => ["sushi", "ZEILE"]}, ["Sushi", "Kino <3D>"], 2, 3750, %{})
    expect.(%{"text" => "pizza & w"}, ["Pizza & Wein"], 1, 4000, %{})
    expect.(%{"text" => nil}, all, 6, 20_520, %{})
    expect.(%{"category" => "none"}, ["Taxi", "Sushi", "Kino <3D>"], 3, 4640, %{})
    expect.(%{"category" => "No Category"}, ["Taxi", "Sushi", "Kino <3D>"], 3, 4640, %{})
    expect.(%{"category" => "REISEN"}, ["Hotel"], 1, 8880, %{})
    expect.(%{"category" => "gesundheit"}, [], 0, 0, %{})

    expect.(
      %{"min_amount" => 12.5, "max_amount" => 30, "sort" => "amount_asc"},
      ["Sushi", "Kino <3D>", "Rewe"],
      3,
      6750,
      %{}
    )

    expect.(%{"min_amount" => 40}, ["Hotel", "Pizza & Wein"], 2, 12_880, %{})
    expect.(%{"max_amount" => 8.9}, ["Taxi"], 1, 890, %{})

    expect.(
      %{"from" => "2026-09-15", "to" => "30.09.2026", "sort" => "date_asc"},
      ["Rewe", "Pizza & Wein", "Hotel"],
      3,
      15_880,
      %{}
    )

    expect.(%{"paid_by" => "Anna", "involved" => "ben"}, ["Sushi", "Rewe"], 2, 4250, %{
      "person_share" => %{"amount" => "15.00", "amount_cents" => 1500, "person" => "Ben"}
    })

    expect.(
      %{"person" => "Ben", "sort" => "amount_desc", "limit" => 2},
      ["Hotel", "Pizza & Wein"],
      5,
      18_020,
      %{
        "person_share" => %{"amount" => "69.42", "amount_cents" => 6942, "person" => "Ben"}
      }
    )

    expect.(%{"person" => "Emil"}, [], 0, 0, %{
      "person_share" => %{"amount" => "0.00", "amount_cents" => 0, "person" => "Emil"}
    })

    expect.(
      %{"paid_by" => "Ben", "reimbursements" => "include"},
      ["Taxi", "Rückzahlung", "Pizza & Wein"],
      3,
      6390,
      %{}
    )

    expect.(%{"sort" => "DATE_ASC", "limit" => 1}, ["Kino <3D>"], 6, 20_520, %{})

    for {args, message} <- [
          {%{"limit" => 1000}, "limit must be between 1 and 500."},
          {%{"limit" => -1}, "limit must be between 1 and 500."},
          {%{"from" => "yesterday"},
           ~s|Invalid date for from: "yesterday" (expected YYYY-MM-DD).|},
          {%{"from" => "2101-01-01"},
           ~s|Invalid date for from: "2101-01-01" (expected YYYY-MM-DD).|},
          {%{"from" => "2026-9-1"}, ~s|Invalid date for from: "2026-9-1" (expected YYYY-MM-DD).|},
          {%{"from" => "02.09.2026", "to" => "1.9.2026"},
           ~s|"to" (2026-09-01) is before "from" (2026-09-02).|},
          {%{"paid_by" => " zoe "}, ~s(Unknown person "zoe". #{@all_people})},
          {%{"involved" => "An"}, ~s(Unknown person "An". #{@all_people})},
          {%{"category" => "Yacht"}, @unknown_category},
          {%{"min_amount" => -1}, "min_amount must be an amount in euros of at least 0."},
          {%{"min_amount" => 2.0e12}, "min_amount must be an amount in euros of at least 0."},
          {%{"max_amount" => 0}, "max_amount must be greater than 0."},
          {%{"max_amount" => 0.004}, "max_amount must be greater than 0."},
          {%{"min_amount" => 10.01, "max_amount" => 10},
           "min_amount (10.01) is greater than max_amount (10.00)."},
          {%{"from" => "x", "person" => "Zoe"},
           ~s|Invalid date for from: "x" (expected YYYY-MM-DD).|},
          {%{"person" => "Zoe", "category" => "Yacht"}, @unknown_category},
          {%{"person" => "Zoe", "limit" => 0}, ~s(Unknown person "Zoe". #{@all_people})}
        ],
        do: assert(refusal("search_expenses", args) == message)

    for {args, field} <- [
          {%{"text" => 5}, "text"},
          {%{"text" => ["a", 1]}, "text"},
          {%{"sort" => "random"}, "sort"},
          {%{"sort" => " date_asc "}, "sort"},
          {%{"von" => "2026-01-01"}, "von"},
          {%{"limit" => "5"}, "limit"},
          {%{"limit" => 5.0}, "limit"},
          {%{"min_amount" => "5"}, "min_amount"},
          {%{"person" => ["Anna"]}, "person"}
        ],
        do: decode_refusal("search_expenses", args, field)
  end

  test "statistics" do
    entries()
    base = "Reimbursements and deleted expenses are not included. count = number of expenses."

    person_note =
      " amount = the person's share (consumption), paid = what they paid for the group."

    compare_note =
      " previous = same group one year earlier, change = amount − previous, change_percent relative to previous " <>
        "(missing if previous is 0)."

    total = "total amounts of the expenses"

    assert ok("statistics", %{"group_by" => "category"}) == %{
             "group_by" => "category",
             "note" => base,
             "period" => "all time",
             "perspective" => total,
             "rows" => [
               %{
                 "category" => "Reisen",
                 "count" => 1,
                 "amount" => "88.80",
                 "amount_cents" => 8880
               },
               %{
                 "category" => "No category",
                 "count" => 3,
                 "amount" => "46.40",
                 "amount_cents" => 4640
               },
               %{
                 "category" => "Restaurant",
                 "count" => 1,
                 "amount" => "40.00",
                 "amount_cents" => 4000
               },
               %{
                 "category" => "Lebensmittel",
                 "count" => 1,
                 "amount" => "30.00",
                 "amount_cents" => 3000
               }
             ],
             "rows_total" => 4,
             "total" => "205.20",
             "total_cents" => 20_520,
             "truncated" => false
           }

    limited = ok("statistics", %{"group_by" => "category", "limit" => 2})

    assert {Enum.map(limited["rows"], & &1["category"]), limited["rows_total"],
            limited["truncated"], limited["total_cents"]} ==
             {["Reisen", "No category"], 4, true, 20_520}

    assert ok("statistics", %{"group_by" => "person"}) == %{
             "group_by" => "person",
             "note" => base <> person_note,
             "period" => "all time",
             "perspective" => total,
             "rows" => [
               %{
                 "person" => "Ben",
                 "count" => 5,
                 "amount" => "69.42",
                 "amount_cents" => 6942,
                 "paid" => "48.90",
                 "paid_cents" => 4890
               },
               %{
                 "person" => "Anna",
                 "count" => 6,
                 "amount" => "64.43",
                 "amount_cents" => 6443,
                 "paid" => "42.50",
                 "paid_cents" => 4250
               },
               %{
                 "person" => "Cleo",
                 "count" => 4,
                 "amount" => "46.92",
                 "amount_cents" => 4692,
                 "paid" => "25.00",
                 "paid_cents" => 2500
               },
               %{
                 "person" => "Dora",
                 "count" => 2,
                 "amount" => "24.43",
                 "amount_cents" => 2443,
                 "paid" => "88.80",
                 "paid_cents" => 8880
               }
             ],
             "rows_total" => 4,
             "total" => "205.20",
             "total_cents" => 20_520,
             "truncated" => false
           }

    assert ok("statistics", %{"group_by" => "person", "category" => "none"})["rows"] == [
             %{
               "person" => "Anna",
               "count" => 3,
               "amount" => "22.23",
               "amount_cents" => 2223,
               "paid" => "12.50",
               "paid_cents" => 1250
             },
             %{
               "person" => "Cleo",
               "count" => 2,
               "amount" => "14.72",
               "amount_cents" => 1472,
               "paid" => "25.00",
               "paid_cents" => 2500
             },
             %{
               "person" => "Ben",
               "count" => 2,
               "amount" => "7.22",
               "amount_cents" => 722,
               "paid" => "8.90",
               "paid_cents" => 890
             },
             %{
               "person" => "Dora",
               "count" => 1,
               "amount" => "2.23",
               "amount_cents" => 223,
               "paid" => "0.00",
               "paid_cents" => 0
             }
           ]

    assert ok("statistics", %{"group_by" => "year"})["rows"] == [
             %{"year" => "2025", "count" => 1, "amount" => "25.00", "amount_cents" => 2500},
             %{"year" => "2026", "count" => 5, "amount" => "180.20", "amount_cents" => 18_020}
           ]

    assert ok("statistics", %{"group_by" => "week", "from" => "2026-09-14"})["rows"] == [
             %{"week" => "2026-W38", "count" => 2, "amount" => "70.00", "amount_cents" => 7000},
             %{"week" => "2026-W39", "count" => 0, "amount" => "0.00", "amount_cents" => 0},
             %{"week" => "2026-W40", "count" => 3, "amount" => "110.20", "amount_cents" => 11_020}
           ]

    summer =
      ok("statistics", %{"group_by" => "month", "from" => "2026-06-15", "to" => "2026-08-31"})

    assert {Enum.map(summer["rows"], & &1["month"]), summer["total_cents"]} ==
             {~w(2026-06 2026-07 2026-08), 0}

    assert ok("statistics", %{
             "group_by" => "title",
             "from" => "2025-09-01",
             "to" => "2026-09-30",
             "share_of" => "anna"
           }) == %{
             "group_by" => "title",
             "note" => base,
             "period" => "2025-09-01 to 2026-09-30",
             "perspective" => "only the share of Anna",
             "rows" => [
               %{"title" => "Hotel", "count" => 1, "amount" => "22.20", "amount_cents" => 2220},
               %{
                 "title" => "Kino <3D>",
                 "count" => 1,
                 "amount" => "12.50",
                 "amount_cents" => 1250
               },
               %{
                 "title" => "Pizza & Wein",
                 "count" => 1,
                 "amount" => "10.00",
                 "amount_cents" => 1000
               },
               %{"title" => "Rewe", "count" => 1, "amount" => "10.00", "amount_cents" => 1000}
             ],
             "rows_total" => 4,
             "total" => "54.70",
             "total_cents" => 5470,
             "truncated" => false
           }

    assert ok("statistics", %{"group_by" => "category_month", "text" => ["hotel", "SUSHI"]})[
             "rows"
           ] == [
             %{
               "category" => "Reisen",
               "month" => "2026-09",
               "count" => 1,
               "amount" => "88.80",
               "amount_cents" => 8880
             },
             %{
               "category" => "No category",
               "month" => "2026-10",
               "count" => 1,
               "amount" => "12.50",
               "amount_cents" => 1250
             }
           ]

    assert ok("statistics", %{"group_by" => "month", "category" => "Restaurant"})["rows"] == [
             %{"month" => "2026-09", "count" => 1, "amount" => "40.00", "amount_cents" => 4000},
             %{"month" => "2026-10", "count" => 0, "amount" => "0.00", "amount_cents" => 0}
           ]

    assert ok("statistics", %{
             "group_by" => "month",
             "from" => "2026-08-01",
             "compare" => "previous_year"
           }) == %{
             "group_by" => "month",
             "note" => base <> compare_note,
             "period" => "from 2026-08-01",
             "perspective" => total,
             "previous_period" => "each month one year earlier",
             "previous_total" => "25.00",
             "previous_total_cents" => 2500,
             "rows" => [
               %{
                 "month" => "2026-08",
                 "count" => 0,
                 "amount" => "0.00",
                 "amount_cents" => 0,
                 "previous" => "0.00",
                 "previous_cents" => 0,
                 "change" => "0.00",
                 "change_cents" => 0
               },
               %{
                 "month" => "2026-09",
                 "count" => 3,
                 "amount" => "158.80",
                 "amount_cents" => 15_880,
                 "previous" => "25.00",
                 "previous_cents" => 2500,
                 "change" => "133.80",
                 "change_cents" => 13_380,
                 "change_percent" => 535.2
               },
               %{
                 "month" => "2026-10",
                 "count" => 2,
                 "amount" => "21.40",
                 "amount_cents" => 2140,
                 "previous" => "0.00",
                 "previous_cents" => 0,
                 "change" => "21.40",
                 "change_cents" => 2140
               }
             ],
             "rows_total" => 3,
             "total" => "180.20",
             "total_cents" => 18_020,
             "truncated" => false
           }

    september =
      ok("statistics", %{
        "group_by" => "category",
        "from" => "2026-09-01",
        "to" => "2026-09-30",
        "compare" => "previous_year"
      })

    assert {september["previous_period"], september["previous_total_cents"]} ==
             {"2025-09-01 to 2025-09-30", 2500}

    assert List.last(september["rows"]) == %{
             "category" => "No category",
             "count" => 0,
             "amount" => "0.00",
             "amount_cents" => 0,
             "previous" => "25.00",
             "previous_cents" => 2500,
             "change" => "-25.00",
             "change_cents" => -2500,
             "change_percent" => -100.0
           }

    cleo =
      ok("statistics", %{
        "group_by" => "person",
        "from" => "2026-09-10",
        "compare" => "previous_year",
        "share_of" => "Cleo"
      })

    assert {cleo["period"], cleo["previous_period"], cleo["perspective"]} ==
             {"2026-09-10 to 2026-10-03", "2025-09-10 to 2025-10-03", "only the share of Cleo"}

    assert cleo["rows"] == [
             %{
               "person" => "Cleo",
               "count" => 3,
               "amount" => "34.42",
               "amount_cents" => 3442,
               "paid" => "0.00",
               "paid_cents" => 0,
               "previous" => "12.50",
               "previous_cents" => 1250,
               "change" => "21.92",
               "change_cents" => 2192,
               "change_percent" => 175.4
             }
           ]

    weeks =
      ok("statistics", %{
        "group_by" => "week",
        "from" => "2026-09-07",
        "to" => "2026-09-20",
        "compare" => "previous_year"
      })

    assert {weeks["previous_period"], weeks["previous_total_cents"]} ==
             {"each week one year earlier", 2500}

    assert Enum.map(weeks["rows"], &{&1["week"], &1["previous_cents"], &1["amount_cents"]}) == [
             {"2026-W37", 2500, 0},
             {"2026-W38", 0, 7000}
           ]

    for {args, message} <- [
          {%{"group_by" => "title", "compare" => "previous_year"},
           "compare=previous_year with group_by=title needs from (and optionally to): the period to compare."},
          {%{"group_by" => "person", "compare" => "previous_year", "from" => "2026-12-01"},
           "from (2026-12-01) is in the future; compare=previous_year needs a period up to today or an explicit to."},
          {%{"group_by" => "month", "limit" => 501}, "limit must be between 1 and 500."},
          {%{"group_by" => "month", "share_of" => "Zoe"},
           ~s(Unknown person "Zoe". #{@all_people})},
          {%{"group_by" => "month", "category" => "Yacht"}, @unknown_category},
          {%{"group_by" => "month", "from" => "heute"},
           ~s|Invalid date for from: "heute" (expected YYYY-MM-DD).|}
        ],
        do: assert(refusal("statistics", args) == message)

    for {args, field} <- [
          {%{}, "group_by"},
          {%{"group_by" => "day"}, "group_by"},
          {%{"group_by" => "month", "compare" => "last_year"}, "compare"},
          {%{"group_by" => "month", "per" => "Anna"}, "per"}
        ],
        do: decode_refusal("statistics", args, field)
  end

  test "activity", people do
    entries()
    all = ok("activity", %{"limit" => 500})["entries"]

    assert length(all) == 14
    assert Enum.all?(all, &(&1["at"] =~ ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(Z|[+-]\d\d:\d\d)\z/))

    assert List.last(all) |> Map.delete("at") |> Map.delete("id") == %{
             "actor" => "Anna",
             "action" => "settings_updated",
             "text" => "Person „Anna“ hinzugefügt"
           }

    [newest | _] = all

    assert Map.drop(newest, ~w(at id expense_id)) == %{
             "actor" => "Ben",
             "action" => "expense_created",
             "title" => "Taxi",
             "amount" => "8.90",
             "amount_cents" => 890,
             "text" => "Über MCP angelegt"
           }

    page = ok("activity", %{"limit" => 3})
    third = Enum.at(all, 2)["id"]

    assert {page["more"], page["shown"], page["note"]} ==
             {true, 3, "There are older entries: call again with before_id=#{third}."}

    assert Enum.map(ok("activity", %{"limit" => 3, "before_id" => third})["entries"], & &1["id"]) ==
             Enum.map(Enum.slice(all, 3, 3), & &1["id"])

    assert Enum.map(ok("activity", %{"person" => "ben"})["entries"], & &1["title"]) == [
             "Taxi",
             "Rückzahlung",
             "Pizza & Wein"
           ]

    assert ok("activity", %{"action" => "settings_updated", "limit" => 7})["shown"] == 7

    assert ok("activity", %{"action" => "expense_deleted"}) == %{
             "entries" => [],
             "more" => false,
             "shown" => 0
           }

    assert ok("activity", %{"person" => "Emil"})["shown"] == 0
    today = Zipfelkasse.LocalTime.today()
    assert ok("activity", %{"from" => Date.to_iso8601(Date.add(today, 1))})["shown"] == 0
    assert ok("activity", %{"to" => Date.to_iso8601(Date.add(today, -1))})["shown"] == 0

    assert ok("activity", %{
             "from" => Date.to_iso8601(today),
             "to" => Date.to_iso8601(today),
             "limit" => 500
           })["shown"] == 14

    {:ok, expense} =
      Expenses.delete_expense(people.anna, Expenses.get_expense!(newest["expense_id"]))

    assert [%{"action" => "expense_deleted"}, %{"action" => "expense_created"}] =
             ok("activity", %{"expense_id" => expense.id})["entries"]

    for {args, message} <- [
          {%{"expense_id" => -1}, "expense_id and before_id must be positive."},
          {%{"before_id" => 0}, "expense_id and before_id must be positive."},
          {%{"limit" => 0}, "limit must be between 1 and 500."},
          {%{"person" => "Zoe"}, ~s(Unknown person "Zoe". #{@all_people})},
          {%{"from" => "2026-10-03", "to" => "2026-10-02"},
           ~s|"to" (2026-10-02) is before "from" (2026-10-03).|}
        ],
        do: assert(refusal("activity", args) == message)

    decode_refusal("activity", %{"expense_id" => 1.5}, "expense_id")
    decode_refusal("activity", %{"actor" => "Anna"}, "actor")
  end

  test "activity shows the changes of an update", people do
    %{"Rewe" => id} = entries()
    expense = Expenses.get_expense!(id)

    {:ok, _expense} =
      Expenses.update_expense(people.anna, expense, %{
        Expenses.input(expense)
        | title: "Rewe City"
      })

    assert [
             %{
               "action" => "expense_updated",
               "changes" => [%{"field" => "Titel", "old" => "Rewe", "new" => "Rewe City"}]
             }
             | _
           ] =
             ok("activity", %{"expense_id" => id})["entries"]
  end

  test "schema" do
    {text, false} = call("schema", %{})

    assert String.starts_with?(
             text,
             "Today is 2026-10-03 (Saturday), server time zone " <>
               (System.get_env("TZ") || "Local") <>
               ~s|. Resolve relative periods such as "last month" from this date.\n\nDatabase of Zipfelkasse (SQLite).|
           )

    assert text =~ "YNAB tables (credentials) are not visible via MCP.\n"
    assert text =~ "GROUP BY 1 ORDER BY 2 DESC;\n\nPeople (id: name): "

    assert text =~
             ~r/People \(id: name\): \d+: Anna, \d+: Ben, \d+: Cleo, \d+: Dora, \d+: Emil \(archived\)\n/

    assert text =~ ~r/\d+: Gesundheit \(archived\)/
    assert text =~ "title_folded"

    tables = for [_, table] <- Regex.scan(~r/^CREATE TABLE "(\w+)"/m, text), do: table

    assert tables ==
             ~w(participants categories settings recurring_expenses expenses expense_shares activities fx_rates)

    refute String.downcase(text) =~ "ynab_"
    decode_refusal("schema", %{"table" => "expenses"}, "table")
  end

  test "sql_query refuses before running anything" do
    assert refusal("sql_query", %{"query" => ""}) == "Parameter query is missing."
    assert refusal("sql_query", %{"query" => " \n\t"}) == "Parameter query is missing."
    assert refusal("sql_query", %{}) == "Parameter query is missing."

    assert refusal("sql_query", %{"query" => "SELECT 1 \u0000"}) ==
             "The query contains a NUL character."

    decode_refusal("sql_query", %{"query" => "SELECT 1", "limit" => 5}, "limit")
    decode_refusal("sql_query", %{"query" => ["SELECT 1"]}, "query")

    assert ok("sql_query", %{
             "query" =>
               "SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite%' ORDER BY name"
           })["rows"] ==
             Enum.map(
               Enum.sort(
                 ~w(activities categories expense_shares expenses fx_rates participants recurring_expenses settings)
               ),
               &[&1]
             )
  end

  describe "category arguments" do
    test "select expenses without a category with none, in any case, and with the statistics label",
         people do
      for {title, category} <- [
            {"Tanken", nil},
            {"Rewe", "Lebensmittel"},
            {"Pizza", "Restaurant"}
          ] do
        args = %{"title" => title, "amount" => "10", "paid_by" => "Anna", "date" => "2026-09-01"}
        ok("create_expense", if(category, do: Map.put(args, "category", category), else: args))
      end

      for category <- ["none", "No category", "NONE"],
          do:
            assert(
              Enum.map(
                ok("search_expenses", %{"category" => category})["expenses"],
                & &1["title"]
              ) == ["Tanken"]
            )

      stats = ok("statistics", %{"group_by" => "category", "category" => "none"})

      assert {Enum.map(stats["rows"], & &1["category"]), stats["total_cents"]} ==
               {["No category"], 1000}

      assert people.anna
    end

    test "prefer a real category named None" do
      {:ok, _none} = Categories.create_category(nil, %{name: "None"})
      ok("create_expense", %{"title" => "Tanken", "amount" => "50", "paid_by" => "Anna"})

      ok("create_expense", %{
        "title" => "Kram",
        "amount" => "10",
        "paid_by" => "Anna",
        "category" => "none"
      })

      assert Enum.map(ok("search_expenses", %{"category" => "none"})["expenses"], & &1["title"]) ==
               ["Kram"]
    end
  end

  describe "statistics compared with the previous year" do
    setup do
      for {title, cents, date, category} <- [
            {"Rewe", "70", "2025-03-10", "Lebensmittel"},
            {"Hotel", "500", "2025-03-12", nil},
            {"Rewe", "100", "2026-03-10", "Lebensmittel"},
            {"Miete", "900", "2023-03-01", nil},
            {"Bäckerei Groß", "3", "2026-05-02", nil},
            {"BÄCKEREI GROSS", "2", "2025-05-02", nil},
            {"Glühwein", "8", "2020-12-30", nil}
          ] do
        args = %{
          "title" => title,
          "amount" => cents,
          "paid_by" => "Anna",
          "participants" => ["Anna"],
          "date" => date
        }

        ok("create_expense", if(category, do: Map.put(args, "category", category), else: args))
      end

      :ok
    end

    test "lists a category that only had expenses a year earlier with 0" do
      stats =
        ok("statistics", %{
          "group_by" => "category_month",
          "from" => "2026-03-01",
          "to" => "2026-03-31",
          "compare" => "previous_year"
        })

      assert stats["rows"] == [
               %{
                 "category" => "Lebensmittel",
                 "month" => "2026-03",
                 "count" => 1,
                 "amount" => "100.00",
                 "amount_cents" => 10_000,
                 "previous" => "70.00",
                 "previous_cents" => 7000,
                 "change" => "30.00",
                 "change_cents" => 3000,
                 "change_percent" => 42.9
               },
               %{
                 "category" => "No category",
                 "month" => "2026-03",
                 "count" => 0,
                 "amount" => "0.00",
                 "amount_cents" => 0,
                 "previous" => "500.00",
                 "previous_cents" => 50_000,
                 "change" => "-500.00",
                 "change_cents" => -50_000,
                 "change_percent" => -100.0
               }
             ]

      assert stats["previous_total_cents"] == 57_000
    end

    test "ends the previous range of 29 February on 28 February" do
      stats =
        ok("statistics", %{
          "group_by" => "category",
          "from" => "2024-02-01",
          "to" => "2024-02-29",
          "compare" => "previous_year"
        })

      assert {stats["previous_total_cents"], stats["previous_period"]} ==
               {0, "2023-02-01 to 2023-02-28"}
    end

    test "matches titles the way the statistics group them, ß as ss" do
      rows =
        ok("statistics", %{
          "group_by" => "title",
          "from" => "2026-05-01",
          "to" => "2026-05-31",
          "compare" => "previous_year"
        })["rows"]

      assert {length(rows), hd(rows)["previous_cents"]} == {1, 200}
    end

    test "compares week 53 of 2020 with week 52 of 2021" do
      weeks =
        &ok("statistics", %{
          "group_by" => "week",
          "from" => &1,
          "to" => &2,
          "compare" => "previous_year"
        })["rows"]

      assert Enum.map(weeks.("2021-12-20", "2021-12-26"), & &1["week"]) == ["2021-W51"]

      assert [%{"week" => "2021-W52", "previous_cents" => 800}] =
               weeks.("2021-12-27", "2022-01-02")
    end

    test "refuses a start in the future without an end" do
      assert refusal("statistics", %{
               "group_by" => "category",
               "from" => "2026-12-01",
               "compare" => "previous_year"
             }) =~ "future"
    end
  end
end
