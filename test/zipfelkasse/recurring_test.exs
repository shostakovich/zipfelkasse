defmodule Zipfelkasse.RecurringTest do
  use Zipfelkasse.DataCase

  @moduletag :capture_log

  import Zipfelkasse.ActivityTexts
  import Zipfelkasse.Fixtures

  alias Zipfelkasse.{Activities, Dates, Expenses, FakeEcb, Fx, LocalTime, Recurring}
  alias Zipfelkasse.Expenses.Expense
  alias Zipfelkasse.Fx.Loader
  alias Zipfelkasse.Recurring.RecurringExpense

  setup do
    %{h: household()}
  end

  defp expense(h, title, date, cents), do: equal(h, title, cents, date, h.anna, [h.anna, h.ben])

  defp cloud(h, opts \\ []) do
    h
    |> foreign(
      Keyword.get(opts, :title, "Cloud"),
      10_000,
      "USD",
      Keyword.get(opts, :rate, 1.1),
      Keyword.get(opts, :on, "2026-01-05"),
      h.anna,
      [h.anna, h.ben]
    )
    |> Map.put(:fx_source, Keyword.get(opts, :source, :ecb))
  end

  defp rule(attrs, frequency, today \\ ~D[2026-01-01]) do
    expense = create!(attrs)
    {:ok, rule, _created} = Recurring.create_rule(nil, expense, frequency, today: today)
    rule
  end

  defp catch_up(today, opts \\ []),
    do: Recurring.catch_up([today: Date.from_iso8601!(today)] ++ opts)

  defp occurrences(rule) do
    Repo.all(
      from e in Expense,
        where: e.recurring_expense_id == ^rule.id and is_nil(e.deleted_at),
        order_by: [e.date, e.id],
        preload: :shares
    )
  end

  defp dates(rule), do: rule |> occurrences() |> Enum.map_join(" ", &Date.to_iso8601(&1.date))

  defp titled(title) do
    Repo.all(
      from e in Expense, where: e.title == ^title and is_nil(e.deleted_at), order_by: e.date
    )
    |> Enum.map_join(" ", &Date.to_iso8601(&1.date))
  end

  defp next_date(rule), do: Date.to_iso8601(Recurring.get_rule!(rule.id).next_date)

  defp ecb!(currency, date, rate),
    do:
      :ok = Fx.save_ecb_rates([%{currency: currency, date: Date.from_iso8601!(date), rate: rate}])

  test "names the frequencies" do
    assert Enum.map(Recurring.frequencies(), &Recurring.frequency_label/1) ==
             ["Wöchentlich", "Monatlich", "Jährlich"]
  end

  describe "creating a rule from an expense" do
    setup %{h: h} do
      expense =
        h |> expense("Miete", "2026-01-31", 100_000) |> Map.put(:notes, "Januar") |> create!()

      {:ok, rule, created} =
        Recurring.create_rule(h.anna, expense, :monthly, today: ~D[2026-02-01])

      %{expense: expense, rule: rule, created: created}
    end

    test "starts at the date of the expense and continues with the next occurrence", %{
      h: h,
      rule: rule
    } do
      assert %RecurringExpense{
               start_date: ~D[2026-01-31],
               next_date: ~D[2026-02-28],
               active: true,
               created_by_id: anna,
               frequency: :monthly
             } = Recurring.get_rule!(rule.id)

      assert anna == h.anna
    end

    test "keeps the expense as the template, without its date", %{rule: rule} do
      template = Recurring.get_rule!(rule.id).template

      assert {template.title, template.amount_cents, template.notes, length(template.parts),
              template.original_currency} ==
               {"Miete", 100_000, "Januar", 2, "EUR"}

      [[json]] = Repo.query!("SELECT template FROM recurring_expenses").rows
      refute Map.has_key?(JSON.decode!(json), "date")
    end

    test "makes the expense the first occurrence of the rule", %{
      h: h,
      expense: expense,
      rule: rule,
      created: created
    } do
      assert created == 0
      assert Expenses.get_expense!(expense.id).recurring_expense_id == rule.id

      # As after a crash before the next date advanced.
      Repo.update_all(where(RecurringExpense, id: ^rule.id), set: [next_date: expense.date])

      assert {:error, %Ecto.Changeset{}} =
               Expenses.create_expense(nil, expense(h, "Miete", "2026-01-31", 100_000),
                 recurring_expense_id: rule.id
               )
    end

    test "refuses a second rule for the same expense, and a deleted expense", %{
      h: h,
      expense: expense
    } do
      assert Recurring.create_rule(h.anna, expense, :weekly) == {:error, :already_recurring}

      other = create!(expense(h, "Kino", "2026-01-31", 1000))
      {:ok, _deleted} = Expenses.delete_expense(nil, other)
      assert Recurring.create_rule(h.anna, other, :weekly) == {:error, :not_found}
    end

    test "logs the new rule with the expense", %{h: h, expense: expense} do
      assert [%{action: :recurring_created, actor_id: anna, details: details} | _] =
               Activities.list_activities(expense_id: expense.id)

      assert anna == h.anna

      assert {details.title, details.amount_cents, details.text} ==
               {"Miete", 100_000, "„Miete“ wiederholt sich jetzt monatlich."}
    end

    test "is due from its next date on", %{rule: rule} do
      assert catch_up("2026-02-27") == {:ok, 0}
      assert catch_up("2026-02-28") == {:ok, 1}
      assert dates(rule) == "2026-01-31 2026-02-28"
    end
  end

  test "creating a rule catches up the occurrences since the expense", %{h: h} do
    expense = create!(expense(h, "Putzen", "2026-09-01", 4000))

    assert {:ok, rule, 4} = Recurring.create_rule(h.anna, expense, :weekly, today: ~D[2026-10-02])
    assert dates(rule) == "2026-09-01 2026-09-08 2026-09-15 2026-09-22 2026-09-29"
  end

  describe "pausing and resuming" do
    setup %{h: h} do
      %{rule: rule(expense(h, "Kino", "2026-01-05", 2000), :weekly)}
    end

    test "makes a paused rule no longer due", %{rule: rule} do
      {:ok, _rule} = Recurring.pause_rule(nil, rule, today: ~D[2026-01-10])

      assert catch_up("2026-03-01") == {:ok, 0}
      assert next_date(rule) == "2026-01-12"
    end

    test "continues with the next occurrence after the resume day, without catching up", %{
      rule: rule
    } do
      {:ok, rule} = Recurring.pause_rule(nil, rule, today: ~D[2026-01-10])

      assert {:ok, %{active: true, next_date: ~D[2026-03-09]}, 0} =
               Recurring.resume_rule(nil, rule, today: ~D[2026-03-04])
    end

    test "counts the occurrence of the resume day itself", %{rule: rule} do
      {:ok, rule} = Recurring.pause_rule(nil, rule, today: ~D[2026-03-05])

      assert {:ok, %{next_date: ~D[2026-03-16]}, 1} =
               Recurring.resume_rule(nil, rule, today: ~D[2026-03-16])

      assert dates(rule) == "2026-01-05 2026-03-16"
    end

    test "logs both changes", %{rule: rule} do
      {:ok, rule} = Recurring.pause_rule(nil, rule, today: ~D[2026-01-10])
      {:ok, _rule, _created} = Recurring.resume_rule(nil, rule, today: ~D[2026-01-10])

      assert Enum.take(activity_texts(), 2) == [
               "Wiederholung „Kino“ (wöchentlich) fortgesetzt",
               "Wiederholung „Kino“ (wöchentlich) pausiert"
             ]
    end

    test "refuse a rule that is gone", %{rule: rule} do
      {:ok, _deleted} = Recurring.delete_rule(nil, rule)

      assert Recurring.pause_rule(nil, rule) == {:error, :not_found}
      assert Recurring.resume_rule(nil, rule) == {:error, :not_found}
    end

    test "a paused rule gets no occurrences", %{h: h, rule: rule} do
      {:ok, _rule} = Recurring.pause_rule(nil, rule)

      assert Expenses.create_expense(nil, expense(h, "Kino", "2026-03-23", 2000),
               recurring_expense_id: rule.id
             ) ==
               {:error, :rule_changed}
    end
  end

  describe "deleting a rule" do
    setup %{h: h} do
      expense = create!(expense(h, "Kino", "2026-01-05", 2000))

      {:ok, rule, _created} =
        Recurring.create_rule(h.anna, expense, :weekly, today: ~D[2026-01-05])

      {:ok, _deleted} = Recurring.delete_rule(h.ben, rule)
      %{expense: expense, rule: rule}
    end

    test "logs the end of the rule", %{h: h} do
      assert [%{action: :recurring_deleted, actor_id: ben, expense_id: nil, details: details} | _] =
               Activities.list_activities()

      assert ben == h.ben

      assert {details.title, details.amount_cents, details.text} ==
               {"Kino", 2000, "Wiederholung von „Kino“ beendet."}
    end

    test "keeps the created expenses and detaches them from the rule", %{expense: expense} do
      assert %{deleted_at: nil, recurring_expense_id: nil} = Expenses.get_expense!(expense.id)
    end

    test "refuses occurrences and further changes", %{h: h, rule: rule} do
      assert Expenses.create_expense(nil, expense(h, "Kino", "2026-03-23", 2000),
               recurring_expense_id: rule.id
             ) ==
               {:error, :rule_changed}

      assert Recurring.get_rule(rule.id) == nil
      assert Recurring.delete_rule(h.ben, rule) == {:error, :not_found}
    end
  end

  describe "taking the template from the newest occurrence" do
    setup %{h: h} do
      rule = rule(expense(h, "Strom", "2026-01-15", 5000), :monthly)
      latest = equal(h, "Strom", 6000, "2026-02-15", h.anna, [h.anna, h.ben, h.cleo])
      {:ok, second} = Expenses.create_expense(nil, latest, recurring_expense_id: rule.id)
      %{rule: rule, second: second}
    end

    test "takes amount and split of the newest occurrence", %{rule: rule} do
      assert {:ok, _rule} = Recurring.refresh_template(nil, rule)

      template = Recurring.get_rule!(rule.id).template
      assert {template.amount_cents, length(template.parts)} == {6000, 3}

      assert hd(activity_texts()) ==
               "Wiederholung „Strom“ (monatlich): Vorlage aus der letzten Ausgabe übernommen"
    end

    test "does not count deleted occurrences", %{rule: rule, second: second} do
      for expense <- occurrences(rule),
          do: {:ok, _deleted} = Expenses.delete_expense(nil, expense)

      assert second.id in Enum.map(Repo.all(Expense), & &1.id)
      assert Recurring.refresh_template(nil, rule) == {:error, :no_occurrence}
    end
  end

  test "lists the active rules first, by next date", %{h: h} do
    later = rule(expense(h, "Strom", "2026-01-20", 5000), :monthly)
    sooner = rule(expense(h, "Miete", "2026-01-10", 5000), :monthly)
    paused = rule(expense(h, "Kino", "2026-01-01", 5000), :monthly)
    {:ok, _rule} = Recurring.pause_rule(nil, paused)

    assert Enum.map(Recurring.list_rules(), & &1.id) == [sooner.id, later.id, paused.id]
  end

  describe "catching up" do
    test "clamps monthly occurrences to the end of the month and returns to the anchor day", %{
      h: h
    } do
      rule = rule(expense(h, "Miete", "2026-01-31", 100_000), :monthly)

      assert catch_up("2026-02-27") == {:ok, 0}
      assert catch_up("2026-05-15") == {:ok, 3}
      assert dates(rule) == "2026-01-31 2026-02-28 2026-03-31 2026-04-30"
      assert next_date(rule) == "2026-05-31"
      assert catch_up("2026-05-15") == {:ok, 0}
      assert catch_up("2026-05-31") == {:ok, 1}
    end

    test "creates occurrences like the template, entered automatically", %{h: h} do
      rule = rule(expense(h, "Miete", "2026-01-31", 100_000), :monthly)
      assert catch_up("2026-03-01") == {:ok, 1}

      for occurrence <- occurrences(rule) do
        assert {occurrence.title, occurrence.amount_cents, length(occurrence.shares),
                occurrence.paid_by_id} ==
                 {"Miete", 100_000, 2, h.anna}
      end

      assert [%{action: :expense_created, actor_id: nil} | _] = Activities.list_activities()
    end

    test "moves a yearly expense of 29 February to the 28th in other years", %{h: h} do
      rule = rule(expense(h, "Versicherung", "2024-02-29", 12_000), :yearly, ~D[2024-03-01])

      assert catch_up("2028-03-01") == {:ok, 4}
      assert dates(rule) == "2024-02-29 2025-02-28 2026-02-28 2027-02-28 2028-02-29"
    end

    test "catches up weekly occurrences", %{h: h} do
      rule = rule(expense(h, "Putzen", "2026-09-01", 4000), :weekly)

      assert catch_up("2026-10-02") == {:ok, 4}
      assert next_date(rule) == "2026-10-06"
    end

    test "creates no duplicates after a crash that left the next date behind", %{h: h} do
      rule = rule(expense(h, "Strom", "2026-01-15", 5000), :monthly)

      {:ok, _crashed} =
        Expenses.create_expense(nil, expense(h, "Strom", "2026-02-15", 5000),
          recurring_expense_id: rule.id
        )

      assert catch_up("2026-03-20") == {:ok, 1}
      assert dates(rule) == "2026-01-15 2026-02-15 2026-03-15"
    end

    test "creates no duplicates after a restart or a reset next date", %{h: h} do
      rule = rule(expense(h, "Strom", "2026-01-15", 5000), :monthly)
      assert catch_up("2026-03-20") == {:ok, 2}
      assert catch_up("2026-03-20") == {:ok, 0}

      Repo.update_all(RecurringExpense, set: [next_date: ~D[2026-01-15]])
      assert catch_up("2026-03-20") == {:ok, 0}
      assert next_date(rule) == "2026-04-15"
    end

    test "does not catch up the occurrences of a paused rule once it is resumed", %{h: h} do
      rule = rule(expense(h, "Kino", "2026-01-10", 2000), :monthly)
      {:ok, rule} = Recurring.pause_rule(nil, rule, today: ~D[2026-01-20])
      assert catch_up("2026-05-01") == {:ok, 0}

      {:ok, _rule, 0} = Recurring.resume_rule(nil, rule, today: ~D[2026-05-01])
      assert catch_up("2026-05-01") == {:ok, 0}
      assert catch_up("2026-05-10") == {:ok, 1}
      assert dates(rule) == "2026-01-10 2026-05-10"
    end

    test "creates at most 400 occurrences per rule and run", %{h: h} do
      rule = rule(expense(h, "Putzen", "2000-01-03", 100), :weekly, ~D[2000-01-03])

      assert catch_up("2026-10-02") == {:ok, 400}
      assert next_date(rule) == Date.to_iso8601(Dates.occurrence(:weekly, ~D[2000-01-03], 401))
      assert catch_up("2026-10-02") == {:ok, 400}
      assert length(occurrences(rule)) == 801
    end

    test "only the rule's own occurrences with catch_up_rule/2", %{h: h} do
      other = rule(expense(h, "Strom", "2026-08-02", 5000), :monthly, ~D[2026-08-02])
      rent = rule(expense(h, "Miete", "2026-08-31", 100_000), :monthly, ~D[2026-08-31])

      assert Recurring.catch_up_rule(rent.id, today: ~D[2026-10-02]) == {:ok, 1}
      assert dates(other) == "2026-08-02"
      assert titled("Miete") == "2026-08-31 2026-09-30"
      assert Recurring.catch_up_rule(rent.id + 100, today: ~D[2026-10-02]) == {:ok, 0}
    end
  end

  describe "foreign currencies" do
    test "convert the amount with the rate of the occurrence date", %{h: h} do
      rule = rule(cloud(h), :monthly)
      ecb!("USD", "2026-02-05", 1.25)

      assert catch_up("2026-02-05") == {:ok, 1}
      [_template, got] = occurrences(rule)

      assert {got.amount_cents, got.fx_rate, got.original_amount, got.original_currency,
              got.fx_source} ==
               {8000, 1.25, 10_000, "USD", :ecb}
    end

    test "keep the template's rate when there is none for the date", %{h: h} do
      rule = rule(cloud(h), :monthly)

      assert catch_up("2026-02-05") == {:ok, 1}
      [_template, got] = occurrences(rule)
      assert {got.amount_cents, got.fx_rate} == {9091, 1.1}
      assert next_date(rule) == "2026-03-05"
    end

    test "do not carry over a manual template rate", %{h: h} do
      rule = rule(cloud(h, rate: 1.3, source: :manual), :monthly)
      ecb!("USD", "2026-02-05", 1.25)
      assert [%{amount_cents: 7692}] = occurrences(rule)

      assert catch_up("2026-02-05") == {:ok, 1}

      assert [_template, %{amount_cents: 8000, fx_rate: 1.25, fx_source: :ecb}] =
               occurrences(rule)
    end

    test "keep fixed amounts in the foreign currency and convert the shares", %{h: h} do
      attrs = %{
        cloud(h, title: "Hotel")
        | split_mode: :amount,
          parts: [%{participant_id: h.anna, weight: 6000}, %{participant_id: h.ben, weight: 4000}]
      }

      rule = rule(attrs, :monthly)
      ecb!("USD", "2026-02-05", 1.25)

      assert catch_up("2026-02-05") == {:ok, 1}
      [_template, got] = occurrences(rule)

      assert {got.amount_cents, Expense.share_of(got, h.anna), Expense.share_of(got, h.ben)} ==
               {8000, 4800, 3200}

      assert Enum.map(got.shares, & &1.weight) == [6000, 4000]
    end

    test "wait while the ECB rates cannot be loaded and catch up with the day's rate later", %{
      h: h
    } do
      rule = rule(cloud(h), :monthly)
      ecb = FakeEcb.start(~D[2026-03-05])
      FakeEcb.put(ecb, :failure, 500)
      clock = fn -> LocalTime.to_utc(~N[2026-03-05 18:00:00]) end
      loader = start_supervised!({Loader, name: nil, base_url: ecb.url, clock: clock})

      assert {:error, 0, [reason]} = catch_up("2026-03-05", loader: loader)

      assert reason =~
               ~s[recurring expense #{rule.id} ("Cloud"): rate for USD on 2026-02-05 not available]

      assert next_date(rule) == "2026-02-05"
      assert dates(rule) == "2026-01-05"

      stop_supervised!(Loader)
      FakeEcb.put(ecb, :failure, nil)
      loader = start_supervised!({Loader, name: nil, base_url: ecb.url, clock: clock})

      assert catch_up("2026-03-05", loader: loader) == {:ok, 2}
      rates = for %{fx_rate: rate} <- tl(occurrences(rule)), do: rate
      assert rates == [FakeEcb.rate!("USD", ~D[2026-02-05]), FakeEcb.rate!("USD", ~D[2026-03-05])]
    end
  end

  describe "occurrences for which an equal expense exists" do
    test "are skipped, and no others", %{h: h} do
      rule = rule(expense(h, "Miete", "2026-01-31", 100_000), :monthly)
      create!(expense(h, " MIETE ", "2026-02-28", 100_000))
      create!(expense(h, "Miete", "2026-03-31", 99_999))
      create!(expense(h, "Mieten", "2026-03-31", 100_000))
      create!(%{expense(h, "Miete", "2026-03-31", 100_000) | paid_by_id: h.ben})
      deleted = create!(expense(h, "Miete", "2026-04-30", 100_000))
      {:ok, _deleted} = Expenses.delete_expense(nil, deleted)

      assert catch_up("2026-05-15") == {:ok, 2}
      assert dates(rule) == "2026-01-31 2026-03-31 2026-04-30"
      assert next_date(rule) == "2026-05-31"
    end

    test "match foreign expenses by original amount and currency", %{h: h} do
      rule = rule(cloud(h), :monthly)
      create!(cloud(h, on: "2026-02-05", rate: 1.111))
      ecb!("USD", "2026-03-05", 1.25)

      assert catch_up("2026-03-05") == {:ok, 1}
      assert dates(rule) == "2026-01-05 2026-03-05"
    end

    test "of a deleted rule are skipped when the expense becomes a rule again", %{h: h} do
      expense = create!(expense(h, "Miete", "2026-01-31", 100_000))
      {:ok, rule, 0} = Recurring.create_rule(nil, expense, :monthly, today: ~D[2026-01-31])
      assert catch_up("2026-05-15") == {:ok, 3}
      {:ok, _deleted} = Recurring.delete_rule(nil, rule)

      expense = Expenses.get_expense!(expense.id)

      assert %{missed: 8, existing: 3} =
               Enum.find(
                 Recurring.previews(expense, today: ~D[2026-10-02]),
                 &(&1.frequency == :monthly)
               )

      assert {:ok, _rule, 5} =
               Recurring.create_rule(nil, expense, :monthly, today: ~D[2026-10-02])

      assert titled("Miete") ==
               "2026-01-31 2026-02-28 2026-03-31 2026-04-30 2026-05-31 2026-06-30 2026-07-31 2026-08-31 2026-09-30"
    end
  end

  describe "a rule changed during its catch-up" do
    setup %{h: h} do
      ecb = FakeEcb.start(~D[2026-05-10])
      clock = fn -> LocalTime.to_utc(~N[2026-05-10 18:00:00]) end
      loader = start_supervised!({Loader, name: nil, base_url: ecb.url, clock: clock})
      %{rule: rule(cloud(h), :monthly), ecb: ecb, loader: loader}
    end

    defp while_loading(%{ecb: ecb, loader: loader}, change) do
      FakeEcb.block(ecb)
      run = Task.async(fn -> catch_up("2026-05-10", loader: loader) end)
      wait_until(fn -> FakeEcb.requests(ecb) != [] end)
      change.()
      FakeEcb.release(ecb)
      Task.await(run)
    end

    defp wait_until(done?) do
      unless done?.() do
        Process.sleep(10)
        wait_until(done?)
      end
    end

    test "stops without an error when it is paused", %{rule: rule} = context do
      assert while_loading(context, fn -> {:ok, _rule} = Recurring.pause_rule(nil, rule) end) ==
               {:ok, 0}

      assert dates(rule) == "2026-01-05"
      assert next_date(rule) == "2026-02-05"
    end

    test "skips what a pause and resume meanwhile skipped", %{rule: rule} = context do
      today = ~D[2026-05-10]

      resume = fn ->
        {:ok, paused} = Recurring.pause_rule(nil, rule, today: today)
        {:ok, _resumed, 0} = Recurring.resume_rule(nil, paused, today: today)
      end

      assert while_loading(context, resume) == {:ok, 0}
      assert dates(rule) == "2026-01-05"
      assert next_date(rule) == "2026-06-05"
    end

    test "stops without an error when it is deleted", %{rule: rule} = context do
      assert while_loading(context, fn -> {:ok, _rule} = Recurring.delete_rule(nil, rule) end) ==
               {:ok, 0}

      assert titled("Cloud") == "2026-01-05"
    end
  end

  describe "previews/2" do
    test "count the missed occurrences per frequency up to more than 1000", %{h: h} do
      expense = create!(expense(h, "Putzen", "2000-01-03", 100))

      assert [
               %{frequency: :weekly, next_date: ~D[2000-01-10], missed: 1001, existing: 0},
               %{frequency: :monthly, next_date: ~D[2000-02-03], missed: 320, existing: 0},
               %{frequency: :yearly, next_date: ~D[2001-01-03], missed: 26, existing: 0}
             ] = Recurring.previews(expense, today: ~D[2026-10-02])
    end

    test "count nothing for an expense from today", %{h: h} do
      expense = create!(expense(h, "Putzen", "2026-10-02", 100))

      assert [%{missed: 0, existing: 0, next_date: ~D[2026-10-09]} | _] =
               Recurring.previews(expense, today: ~D[2026-10-02])
    end
  end
end
