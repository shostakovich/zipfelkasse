defmodule Zipfelkasse.ExportsTest do
  use Zipfelkasse.DataCase

  alias Zipfelkasse.{Categories, Expenses, Exports, Participants, Settings}
  alias Zipfelkasse.Expenses.Expense
  alias Zipfelkasse.Ynab.{Connections, Transaction, Transactions}

  @now ~U[2026-10-03 10:00:00Z]
  @opts [now: @now, today: ~D[2026-10-03]]
  @header "ID;Datum;Titel;Kategorie;Bezahlt von;Betrag (EUR);Originalbetrag;Währung;Kurs;Art;Aufteilung;Notiz"
  @long_title "Sehr langer Titel mit <Sonderzeichen> & mehr Text dahinter"

  for {text, cell} <- [
        {"=SUM(A1)", "'=SUM(A1)"},
        {"+49 Telefon", "'+49 Telefon"},
        {"-Rabatt", "'-Rabatt"},
        {"@home", "'@home"},
        {"\tTab", "'\tTab"},
        {"\rReturn", "'\rReturn"},
        {"Miete", "Miete"},
        {"a=b", "a=b"},
        {"", ""}
      ] do
    test "turns #{inspect(text)} into the cell #{inspect(cell)}" do
      assert Exports.cell(unquote(text)) == unquote(cell)
    end
  end

  describe "SGML text" do
    test "collapses whitespace and line breaks" do
      assert Exports.sgml("Zeile 1\n  Zeile\t2", 100) == "Zeile 1 Zeile 2"
    end

    test "cuts to the length before escaping and drops the blank at the cut" do
      assert Exports.sgml("Sehr langer Titel mit <Sonderzeichen>", 32) ==
               "Sehr langer Titel mit &lt;Sonderzei"

      assert Exports.sgml("ab cd", 3) == "ab"
    end

    test "escapes ampersands and angle brackets" do
      assert Exports.sgml("Café & <Kuchen>", 100) == "Café &amp; &lt;Kuchen&gt;"
    end
  end

  describe "the period" do
    test "has inclusive, optional ends" do
      assert Exports.period(%{}) == {:ok, %{from: nil, to: nil}}

      assert Exports.period(%{"from" => "1.9.2026", "to" => ""}) ==
               {:ok, %{from: ~D[2026-09-01], to: nil}}

      assert Exports.period(%{"from" => "2026-09-01", "to" => "2026-09-01"}) ==
               {:ok, %{from: ~D[2026-09-01], to: ~D[2026-09-01]}}
    end

    test "refuses invalid dates and an end before the start" do
      for {params, message} <- [
            {%{"from" => "broken"}, "Ungültiges Datum „broken“."},
            {%{"from" => "2026-09-01", "to" => "31.02.2026"}, "Ungültiges Datum „31.02.2026“."},
            {%{"to" => "1999-12-31"},
             "Das Datum „1999-12-31“ liegt nicht zwischen 2000 und 2100."},
            {%{"from" => " "}, "Bitte ein Datum angeben."},
            {%{"from" => "2026-09-30", "to" => "29.09.2026"}, "„Bis“ liegt vor „Von“."}
          ],
          do: assert(Exports.period(params) == {:error, message})
    end
  end

  defp period(from \\ nil, to \\ nil),
    do: %{from: from && Date.from_iso8601!(from), to: to && Date.from_iso8601!(to)}

  describe "a household with every kind of expense" do
    setup do
      {:ok, anna} = Participants.join(%{name: "Anna"})

      people =
        Map.new(~w(Ben Dora Emil Jürgen Xaver), fn name ->
          {:ok, person} = Participants.create_participant(anna.id, %{name: name})
          {name, person.id}
        end)
        |> Map.put("Anna", anna.id)

      {:ok, _xaver} =
        Participants.archive_participant(nil, Participants.get_participant!(people["Xaver"]))

      {:ok, _settings} = Settings.update_settings(nil, %{group_name: ~s(WG <Zipfel> & "Co")})
      categories = Map.new(Categories.list_categories(), &{&1.name, &1.id})
      [anna, ben, dora, jue] = Enum.map(~w(Anna Ben Dora Jürgen), &people[&1])

      inputs = [
        {"Brötchen", "2026-08-30", 400, jue, [{anna, 0}, {jue, 0}], []},
        {"Café & Kuchen", "2026-09-01", 1201, anna, [{anna, 0}, {jue, 0}],
         category_id: categories["Restaurant"], notes: "lecker; „süß“"},
        {~s(Diner "NYC"), "2026-09-03", 0, ben, [{anna, 0}, {ben, 0}],
         original_currency: "USD", original_amount: 9000, fx_rate: 1.125, fx_source: :manual},
        {"Rückzahlung", "2026-09-05", 600, jue, [{anna, 0}], reimbursement: true},
        {"=SUMME(A1)", "2026-09-10", 500, ben, [{ben, 0}],
         category_id: categories["Lebensmittel"]},
        {~s(=Formel <&> "q"), "2026-09-05", 1000, anna, [{anna, 2}, {jue, 1}],
         split_mode: :shares, notes: "Zeile1\nZeile2\r\nZeile3; x"},
        {"Sushi", "2026-09-06", 0, anna, [{anna, 0}, {jue, 0}],
         original_currency: "JPY", original_amount: 2000, fx_rate: 160.5, fx_source: :manual},
        {"+49 Telefon", "2026-09-07", 2000, ben, [{anna, 2500}, {ben, 7500}],
         split_mode: :percent, category_id: categories["Haushalt"], notes: "@home"},
        {"-Rabatt", "2026-09-08", 750, dora, [{anna, 750}, {ben, 0}], split_mode: :amount},
        {"Gelöscht", "2026-09-09", 100, anna, [{anna, 0}], []},
        {"Konzert", "2026-12-04", 5000, ben, [{anna, 0}, {ben, 0}], []},
        {@long_title, "2026-09-12", 999, anna, [{anna, 0}, {ben, 0}, {dora, 0}], []},
        {"Heute", "2026-10-03", 300, anna, [{anna, 0}, {ben, 0}], []}
      ]

      ids =
        for {{title, date, cents, payer, parts, extra}, index} <- Enum.with_index(inputs, 1) do
          attrs =
            Map.merge(
              %{
                title: title,
                date: Date.from_iso8601!(date),
                paid_by_id: payer,
                amount_cents: cents,
                parts:
                  Enum.map(parts, fn {id, weight} -> %{participant_id: id, weight: weight} end)
              },
              Map.new(extra)
            )

          {:ok, expense} = Expenses.create_expense(payer, attrs)
          assert expense.id == index
          expense.id
        end

      {:ok, _deleted} = Expenses.delete_expense(anna, Expenses.get_expense!(Enum.at(ids, 9)))
      %{people: people}
    end

    test "the CSV for German Excel has every expense with the shares of the people involved" do
      file = Exports.expenses_csv(period(), @opts)

      assert {file.filename, file.content_type} ==
               {"zipfelkasse-ausgaben-2026-10-03.csv", "text/csv; charset=utf-8"}

      assert file.body ==
               "\uFEFF" <>
                 Enum.map_join(
                   [
                     "#{@header};Anteil Anna;Anteil Ben;Anteil Dora;Anteil Jürgen",
                     "1;30.08.2026;Brötchen;;Jürgen;4,00;4,00;EUR;;Ausgabe;Gleichmäßig;;2,00;;;2,00",
                     "2;01.09.2026;Café & Kuchen;Restaurant;Anna;12,01;12,01;EUR;;Ausgabe;Gleichmäßig;\"lecker; „süß“\";6,01;;;6,00",
                     "3;03.09.2026;\"Diner \"\"NYC\"\"\";;Ben;80,00;90,00;USD;1,125;Ausgabe;Gleichmäßig;;40,00;40,00;;",
                     "4;05.09.2026;Rückzahlung;;Jürgen;6,00;6,00;EUR;;Rückzahlung;Gleichmäßig;;6,00;;;",
                     "6;05.09.2026;\"'=Formel <&> \"\"q\"\"\";;Anna;10,00;10,00;EUR;;Ausgabe;Nach Anteilen;\"Zeile1\nZeile2\r\nZeile3; x\";6,67;;;3,33",
                     "7;06.09.2026;Sushi;;Anna;12,46;2000;JPY;160,5;Ausgabe;Gleichmäßig;;6,23;;;6,23",
                     "8;07.09.2026;'+49 Telefon;Haushalt;Ben;20,00;20,00;EUR;;Ausgabe;Nach Prozent;'@home;5,00;15,00;;",
                     "9;08.09.2026;'-Rabatt;;Dora;7,50;7,50;EUR;;Ausgabe;Nach Beträgen;;7,50;0,00;;",
                     "5;10.09.2026;'=SUMME(A1);Lebensmittel;Ben;5,00;5,00;EUR;;Ausgabe;Gleichmäßig;;;5,00;;",
                     "12;12.09.2026;#{@long_title};;Anna;9,99;9,99;EUR;;Ausgabe;Gleichmäßig;;3,33;3,33;3,33;",
                     "13;03.10.2026;Heute;;Anna;3,00;3,00;EUR;;Ausgabe;Gleichmäßig;;1,50;1,50;;",
                     "11;04.12.2026;Konzert;;Ben;50,00;50,00;EUR;;Ausgabe;Gleichmäßig;;25,00;25,00;;"
                   ],
                   &(&1 <> "\n")
                 )

      assert Exports.expenses_csv(period("2026-12-01"), @opts).filename ==
               "zipfelkasse-ausgaben-ab-2026-12-01.csv"

      assert Exports.expenses_csv(period(nil, "2026-08-31"), @opts).body ==
               "\uFEFF#{@header};Anteil Anna;Anteil Jürgen\n1;30.08.2026;Brötchen;;Jürgen;4,00;4,00;EUR;;Ausgabe;Gleichmäßig;;2,00;2,00\n"

      empty = Exports.expenses_csv(period("2020-01-01", "2020-01-02"), @opts)

      assert {empty.filename, empty.body} ==
               {"zipfelkasse-ausgaben-2020-01-01_2020-01-02.csv", "\uFEFF#{@header}\n"}
    end

    test "the JSON has everything with shares", %{people: people} do
      file = Exports.expenses_json(period("2026-09-03", "2026-09-06"), @opts)

      assert {file.filename, file.content_type} ==
               {"zipfelkasse-ausgaben-2026-09-03_2026-09-06.json",
                "application/json; charset=utf-8"}

      assert String.ends_with?(file.body, "}\n")
      assert file.body =~ ~s(\n  "currency": "EUR")
      json = JSON.decode!(file.body)

      assert Map.drop(json, ["expenses"]) == %{
               "group" => ~s(WG <Zipfel> & "Co"),
               "exported_at" => "2026-10-03T10:00:00Z",
               "from" => "2026-09-03",
               "to" => "2026-09-06",
               "currency" => "EUR",
               "participants" =>
                 for name <- ~w(Anna Ben Dora Emil Jürgen Xaver) do
                   %{"id" => people[name], "name" => name, "archived" => name == "Xaver"}
                 end
             }

      share = fn name, weight, cents ->
        %{
          "participant_id" => people[name],
          "name" => name,
          "weight" => weight,
          "amount_cents" => cents
        }
      end

      [diner, reimbursement, formula, sushi] = json["expenses"]

      assert Map.drop(diner, ["created_at", "updated_at"]) == %{
               "id" => 3,
               "date" => "2026-09-03",
               "title" => ~s(Diner "NYC"),
               "category_id" => nil,
               "category" => "",
               "paid_by" => people["Ben"],
               "paid_by_name" => "Ben",
               "amount_cents" => 8000,
               "is_reimbursement" => false,
               "split_mode" => "equal",
               "original_amount_minor" => 9000,
               "original_currency" => "USD",
               "fx_rate" => 1.125,
               "fx_source" => "manuell",
               "notes" => "",
               "recurring_id" => nil,
               "shares" => [share.("Anna", 1, 4000), share.("Ben", 1, 4000)]
             }

      assert diner["created_at"] =~ ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/

      assert {reimbursement["is_reimbursement"], reimbursement["fx_source"],
              reimbursement["fx_rate"], reimbursement["shares"]} ==
               {true, "", 1.0, [share.("Anna", 1, 600)]}

      assert {formula["split_mode"], formula["notes"], formula["shares"]} ==
               {"shares", "Zeile1\nZeile2\r\nZeile3; x",
                [share.("Anna", 2, 667), share.("Jürgen", 1, 333)]}

      assert {sushi["original_amount_minor"], sushi["fx_rate"], sushi["amount_cents"]} ==
               {2000, 160.5, 1246}

      all = JSON.decode!(Exports.expenses_json(period(), @opts).body)
      assert Enum.sort(Map.keys(all)) == ~w(currency expenses exported_at group participants)
      assert Enum.map(all["expenses"], & &1["id"]) == [1, 2, 3, 4, 6, 7, 8, 9, 5, 12, 13, 11]
      phone = Enum.find(all["expenses"], &(&1["id"] == 8))

      assert {phone["category"], phone["shares"]} ==
               {"Haushalt", [share.("Anna", 2500, 500), share.("Ben", 7500, 1500)]}
    end

    defp memo(total, extra, payer, id),
      do: "Gesamt #{total} €#{extra} · bezahlt von #{payer} · zipfelkasse ##{id}"

    defp transaction(date, amount, id, name, memo) do
      [
        "<STMTTRN>",
        "<TRNTYPE>DEBIT",
        "<DTPOSTED>#{date}",
        "<TRNAMT>#{amount}",
        "<FITID>zipfelkasse-#{id}",
        "<NAME>#{name}",
        "<MEMO>#{memo}",
        "</STMTTRN>"
      ]
    end

    defp ofx(account, from, to, server, transactions, balance) do
      head =
        ~w(OFXHEADER:100 DATA:OFXSGML VERSION:102 SECURITY:NONE ENCODING:UTF-8 CHARSET:NONE COMPRESSION:NONE OLDFILEUID:NONE NEWFILEUID:NONE) ++
          [
            "",
            "<OFX>",
            "<SIGNONMSGSRSV1>",
            "<SONRS>",
            "<STATUS>",
            "<CODE>0",
            "<SEVERITY>INFO",
            "</STATUS>",
            "<DTSERVER>#{server}",
            "<LANGUAGE>GER"
          ] ++
          [
            "</SONRS>",
            "</SIGNONMSGSRSV1>",
            "<BANKMSGSRSV1>",
            "<STMTTRNRS>",
            "<TRNUID>1",
            "<STATUS>",
            "<CODE>0",
            "<SEVERITY>INFO",
            "</STATUS>"
          ] ++
          [
            "<STMTRS>",
            "<CURDEF>EUR",
            "<BANKACCTFROM>",
            "<BANKID>ZIPFEL",
            "<ACCTID>#{account}",
            "<ACCTTYPE>CHECKING",
            "</BANKACCTFROM>"
          ] ++
          ["<BANKTRANLIST>", "<DTSTART>#{from}", "<DTEND>#{to}"]

      tail = [
        "</BANKTRANLIST>",
        "<LEDGERBAL>",
        "<BALAMT>#{balance}",
        "<DTASOF>#{to}",
        "</LEDGERBAL>",
        "</STMTRS>",
        "</STMTTRNRS>",
        "</BANKMSGSRSV1>",
        "</OFX>"
      ]

      Enum.map_join(head ++ List.flatten(transactions) ++ tail, &(&1 <> "\r\n"))
    end

    defp annas_transactions do
      [
        transaction("20260830", "-2.00", 1, "Brötchen", memo("4,00", "", "Jürgen", 1)),
        transaction("20260901", "-6.01", 2, "Café &amp; Kuchen", memo("12,01", "", "Anna", 2)),
        transaction(
          "20260903",
          "-40.00",
          3,
          ~s(Diner "NYC"),
          memo("80,00", " (90,00 USD)", "Ben", 3)
        ),
        transaction(
          "20260905",
          "-6.67",
          6,
          ~s(=Formel &lt;&amp;&gt; "q"),
          memo("10,00", "", "Anna", 6)
        ),
        transaction("20260906", "-6.23", 7, "Sushi", memo("12,46", " (2.000 JPY)", "Anna", 7)),
        transaction("20260907", "-5.00", 8, "+49 Telefon", memo("20,00", "", "Ben", 8)),
        transaction("20260908", "-7.50", 9, "-Rabatt", memo("7,50", "", "Dora", 9)),
        transaction(
          "20260912",
          "-3.33",
          12,
          "Sehr langer Titel mit &lt;Sonderzei",
          memo("9,99", "", "Anna", 12)
        ),
        transaction("20261003", "-1.50", 13, "Heute", memo("3,00", "", "Anna", 13))
      ]
    end

    test "the OFX statement for YNAB holds my shares up to today", %{people: people} do
      anna = Participants.get_participant!(people["Anna"])
      account = "ZIPFELKASSE-#{anna.id}"
      transactions = annas_transactions()
      file = Exports.ynab_ofx(anna, period(), @opts)

      assert {file.filename, file.content_type} ==
               {"zipfelkasse-ynab-2026-10-03.ofx", "application/x-ofx"}

      assert file.body ==
               ofx(account, "20260830", "20261003", "20261003100000", transactions, "-78.24")

      assert Exports.ynab_ofx(anna, period("2026-09-06"), @opts).body ==
               ofx(
                 account,
                 "20260906",
                 "20261003",
                 "20261003100000",
                 Enum.drop(transactions, 4),
                 "-23.56"
               )

      assert Exports.ynab_ofx(anna, period("2026-09-01", "2026-09-05"), @opts).body ==
               ofx(
                 account,
                 "20260901",
                 "20260905",
                 "20261003100000",
                 Enum.slice(transactions, 1..3),
                 "-52.68"
               )

      assert Exports.ynab_ofx(anna, period("2020-01-01", "2020-01-02"), @opts).body ==
               ofx(account, "20200101", "20200102", "20261003100000", [], "0.00")

      emil = Participants.get_participant!(people["Emil"])

      assert Exports.ynab_ofx(emil, period(), @opts).body ==
               ofx("ZIPFELKASSE-#{emil.id}", "20261003", "20261003", "20261003100000", [], "0.00")
    end

    test "the YNAB CSV holds the same postings", %{people: people} do
      anna = Participants.get_participant!(people["Anna"])
      file = Exports.ynab_csv(anna, period(), @opts)

      assert {file.filename, file.content_type} ==
               {"zipfelkasse-ynab-2026-10-03.csv", "text/csv; charset=utf-8"}

      assert String.split(file.body, "\n") == [
               "Date,Payee,Memo,Outflow,Inflow",
               "2026-08-30,Brötchen,\"Gesamt 4,00 € · bezahlt von Jürgen · zipfelkasse #1\",2.00,",
               "2026-09-01,Café & Kuchen,\"Gesamt 12,01 € · bezahlt von Anna · zipfelkasse #2\",6.01,",
               "2026-09-03,\"Diner \"\"NYC\"\"\",\"Gesamt 80,00 € (90,00 USD) · bezahlt von Ben · zipfelkasse #3\",40.00,",
               "2026-09-05,\"'=Formel <&> \"\"q\"\"\",\"Gesamt 10,00 € · bezahlt von Anna · zipfelkasse #6\",6.67,",
               "2026-09-06,Sushi,\"Gesamt 12,46 € (2.000 JPY) · bezahlt von Anna · zipfelkasse #7\",6.23,",
               "2026-09-07,'+49 Telefon,\"Gesamt 20,00 € · bezahlt von Ben · zipfelkasse #8\",5.00,",
               "2026-09-08,'-Rabatt,\"Gesamt 7,50 € · bezahlt von Dora · zipfelkasse #9\",7.50,",
               "2026-09-12,#{@long_title},\"Gesamt 9,99 € · bezahlt von Anna · zipfelkasse #12\",3.33,",
               "2026-10-03,Heute,\"Gesamt 3,00 € · bezahlt von Anna · zipfelkasse #13\",1.50,",
               ""
             ]

      ben = Participants.get_participant!(people["Ben"])

      lines =
        String.split(Exports.ynab_csv(ben, period("2026-09-07"), @opts).body, "\n", trim: true)

      assert Enum.map(tl(lines), &String.slice(&1, 0, 10)) ==
               ~w(2026-09-07 2026-09-10 2026-09-12 2026-10-03)

      assert Exports.ynab_csv(Participants.get_participant!(people["Emil"]), period(), @opts).body ==
               "Date,Payee,Memo,Outflow,Inflow\n"
    end

    test "shortly after midnight the YNAB files end with the UTC date", %{people: people} do
      anna = Participants.get_participant!(people["Anna"])
      opts = [now: ~U[2026-10-02 22:30:00Z], today: ~D[2026-10-03]]

      file = Exports.ynab_ofx(anna, period(), opts)
      assert file.filename == "zipfelkasse-ynab-2026-10-03.ofx"

      assert file.body ==
               ofx(
                 "ZIPFELKASSE-#{anna.id}",
                 "20260830",
                 "20260912",
                 "20261002223000",
                 Enum.take(annas_transactions(), 8),
                 "-76.74"
               )

      assert Exports.expenses_csv(period("2026-10-01", "2026-10-31"), opts).body =~
               "13;03.10.2026;Heute"
    end
  end

  describe "the JSON file" do
    test "keeps its keys in the documented order" do
      {:ok, anna} = Participants.join(%{name: "Anna"})
      {:ok, ben} = Participants.create_participant(anna.id, %{name: "Ben"})
      food = Enum.find(Categories.list_categories(), &(&1.name == "Lebensmittel"))

      {:ok, expense} =
        Expenses.create_expense(anna.id, %{
          title: "Rewe",
          date: ~D[2026-09-01],
          paid_by_id: anna.id,
          category_id: food.id,
          amount_cents: 1001,
          notes: "Wochenende",
          parts: [%{participant_id: anna.id, weight: 0}, %{participant_id: ben.id, weight: 0}]
        })

      Repo.update_all(where(Expense, id: ^expense.id),
        set: [
          inserted_at: ~U[2026-09-01 18:00:00.123456Z],
          updated_at: ~U[2026-09-02 07:30:00.000000Z]
        ]
      )

      assert Exports.expenses_json(period("2026-09-01", "2026-09-30"), @opts).body == """
             {
               "group": "Zipfelkasse",
               "exported_at": "2026-10-03T10:00:00Z",
               "from": "2026-09-01",
               "to": "2026-09-30",
               "currency": "EUR",
               "participants": [
                 {
                   "id": #{anna.id},
                   "name": "Anna",
                   "archived": false
                 },
                 {
                   "id": #{ben.id},
                   "name": "Ben",
                   "archived": false
                 }
               ],
               "expenses": [
                 {
                   "id": #{expense.id},
                   "date": "2026-09-01",
                   "title": "Rewe",
                   "category_id": #{food.id},
                   "category": "Lebensmittel",
                   "paid_by": #{anna.id},
                   "paid_by_name": "Anna",
                   "amount_cents": 1001,
                   "is_reimbursement": false,
                   "split_mode": "equal",
                   "original_amount_minor": 1001,
                   "original_currency": "EUR",
                   "fx_rate": 1.0,
                   "fx_source": "",
                   "notes": "Wochenende",
                   "recurring_id": null,
                   "shares": [
                     {
                       "participant_id": #{anna.id},
                       "name": "Anna",
                       "weight": 1,
                       "amount_cents": 500
                     },
                     {
                       "participant_id": #{ben.id},
                       "name": "Ben",
                       "weight": 1,
                       "amount_cents": 501
                     }
                   ],
                   "created_at": "2026-09-01T18:00:00Z",
                   "updated_at": "2026-09-02T07:30:00Z"
                 }
               ]
             }
             """
    end
  end

  describe "the YNAB exports of a connected person" do
    setup do
      [anna, ben] =
        for name <- ~w(Anna Ben) do
          {:ok, person} = Participants.create_participant(nil, %{name: name})
          person
        end

      create = fn title, date, payer, people, entered_at ->
        {:ok, expense} =
          Expenses.create_expense(nil, %{
            title: title,
            date: Date.from_iso8601!(date),
            paid_by_id: payer.id,
            amount_cents: 1000,
            parts: Enum.map(people, &%{participant_id: &1.id, weight: 0})
          })

        Repo.update_all(where(Expense, id: ^expense.id), set: [inserted_at: entered_at])
        expense
      end

      entered = ~U[2026-09-10 00:00:00.000000Z]
      broetchen = create.("Brötchen", "2026-08-30", ben, [anna, ben], entered)
      create.("Käse", "2026-09-02", ben, [anna, ben], entered)
      create.("Nur Ben", "2026-09-04", ben, [ben], entered)
      create.("Zukunft", "2026-10-04", ben, [anna, ben], entered)
      %{anna: anna, ben: ben, create: create, broetchen: broetchen}
    end

    defp payees(file),
      do:
        file.body
        |> String.split("\n", trim: true)
        |> tl()
        |> Enum.map(&(&1 |> String.split(",") |> Enum.at(1)))

    defp connect(anna, at) do
      {:ok, false} = Connections.put_token(anna.id, "token")

      {:ok, _changed} =
        Connections.put_target(
          anna.id,
          %{
            plan_id: "plan",
            account_id: "account",
            plan_name: nil,
            account_name: nil,
            start: ~D[2026-09-01]
          },
          at
        )
    end

    test "contain the person's past expenses without a connection", %{anna: anna} do
      assert payees(Exports.ynab_csv(anna, period(), @opts)) == ["Brötchen", "Käse"]
    end

    test "contain what the YNAB sync transfers", %{anna: anna, ben: ben, create: create} do
      connected_at = ~U[2026-09-21 12:00:00.000000Z]
      connect(anna, connected_at)
      create.("Nachgetragen", "2026-08-15", ben, [anna, ben], DateTime.add(connected_at, 60))

      assert payees(Exports.ynab_csv(anna, period(), @opts)) == ["Nachgetragen", "Käse"]
    end

    test "keep an expense that is already in YNAB although it is dated before the start",
         %{anna: anna, broetchen: broetchen} do
      connect(anna, ~U[2026-09-21 12:00:00.000000Z])

      Transactions.put([
        %Transaction{
          expense_id: broetchen.id,
          participant_id: anna.id,
          ynab_transaction_id: "t1",
          state: :synced,
          fingerprint: "hash"
        }
      ])

      assert payees(Exports.ynab_csv(anna, period(), @opts)) == ["Brötchen", "Käse"]
    end

    test "write nothing", %{anna: anna} do
      connect(anna, ~U[2026-09-21 12:00:00.000000Z])
      Repo.update_all(Zipfelkasse.Ynab.Connection, set: [connected_at: nil])

      Exports.ynab_csv(anna, period(), @opts)

      assert Connections.get(anna.id).connected_at == nil
    end
  end
end
