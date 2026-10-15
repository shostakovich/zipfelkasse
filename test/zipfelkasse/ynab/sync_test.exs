defmodule Zipfelkasse.Ynab.SyncTest do
  use Zipfelkasse.DataCase

  @moduletag :capture_log

  import ExUnit.CaptureLog
  import Zipfelkasse.Fixtures

  alias Zipfelkasse.{Categories, Expenses, FakeYnab, LocalTime, Participants}
  alias Zipfelkasse.Expenses.Expense
  alias Zipfelkasse.Ynab.{Connections, Error, Result, Scheduler, Sync, Transactions}

  @now ~U[2026-10-02 12:00:00.000000Z]
  @transactions "/v1/plans/plan-1/transactions"
  @post "POST " <> @transactions
  @patch "PATCH " <> @transactions
  @list_shared "GET /v1/plans/plan-1/accounts/acc-geteilt/transactions"
  @list_giro "GET /v1/plans/plan-1/accounts/acc-giro/transactions"

  setup do
    %{fake: FakeYnab.start(), h: household()}
  end

  defp target(account, start) do
    %{
      plan_id: FakeYnab.plan(),
      account_id: account,
      plan_name: nil,
      account_name: nil,
      start: Date.from_iso8601!(start)
    }
  end

  defp connect(h, opts \\ []) do
    {:ok, _reset?} = Connections.put_token(h.anna, FakeYnab.token())

    {:ok, _changed} =
      Connections.put_target(
        h.anna,
        target(opts[:account] || FakeYnab.account(), opts[:start] || "2026-09-01"),
        opts[:at] || @now
      )
  end

  defp retarget(h, account, start, at \\ @now),
    do: {:ok, _changed} = Connections.put_target(h.anna, target(account, start), at)

  # Anna pays and shares with Ben, in the category Lebensmittel.
  defp shared(h, title, cents, date), do: equal(h, title, cents, date, h.anna, [h.anna, h.ben])

  defp create(attrs, entered_at \\ nil) do
    expense = create!(attrs, attrs.paid_by_id)

    if entered_at,
      do: Repo.update_all(where(Expense, id: ^expense.id), set: [inserted_at: entered_at])

    expense.id
  end

  defp edit(h, id, fun) do
    expense = Expenses.get_expense!(id)
    {:ok, _expense} = Expenses.update_expense(h.anna, expense, fun.(Expenses.input(expense)))
  end

  defp delete(h, id),
    do: {:ok, _deleted} = Expenses.delete_expense(h.anna, Expenses.get_expense!(id))

  defp sync(h, opts \\ []),
    do: Sync.sync_person(h.anna, Keyword.get(opts, :full, false), now: opts[:now] || @now)

  defp sync!(h, opts \\ []) do
    outcome = sync(h, opts)
    assert outcome.error == nil, inspect(outcome)
    outcome.result
  end

  defp status(h), do: Connections.get(h.anna)
  defp rows(h), do: Map.new(Transactions.list(h.anna), &{&1.expense_id, &1})
  defp requests(fake), do: FakeYnab.take_requests(fake)
  defp later(minutes), do: DateTime.add(@now, minutes, :minute)

  defp eventually(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not reached")
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end

  defp marker(id), do: "zipfelkasse ##{id}"

  describe "creating, updating and deleting transactions" do
    test "creates a transaction with the person's share as an outflow in the mapped category",
         %{h: h, fake: fake} do
      connect(h)
      {:ok, _changed} = Connections.put_category_mapping(h.anna, %{h.food => "c-food"}, %{})
      id = create(shared(h, "Einkauf Rewe", 8400, "2026-09-15"))

      assert sync!(h).created == 1

      assert requests(fake) == [@post]
      [transaction] = FakeYnab.live(fake)

      assert Map.take(transaction, [
               :amount,
               :date,
               :payee_name,
               :category_id,
               :account_id,
               :cleared,
               :approved
             ]) ==
               %{
                 amount: -42_000,
                 date: "2026-09-15",
                 payee_name: "Einkauf Rewe",
                 category_id: "c-food",
                 account_id: "acc-geteilt",
                 cleared: "cleared",
                 approved: true
               }

      assert transaction.memo == "Gesamt 84,00 € · bezahlt von Anna · #{marker(id)}"

      assert %{
               ynab_transaction_id: txn_id,
               state: :synced,
               synced_at: %DateTime{},
               last_error: nil
             } =
               rows(h)[id]

      assert txn_id == transaction.id
    end

    test "sends nothing when nothing changed, not even in a full sync", %{h: h, fake: fake} do
      connect(h)
      create(shared(h, "Einkauf", 8400, "2026-09-15"))
      sync!(h)
      requests(fake)

      assert sync!(h, full: true) == %Result{}
      assert requests(fake) == []
    end

    test "updates the transaction of a changed expense", %{h: h, fake: fake} do
      connect(h)
      id = create(shared(h, "Einkauf", 8400, "2026-09-15"))
      sync!(h)

      edit(h, id, &%{&1 | title: "Einkauf groß", amount_cents: 10_000, date: ~D[2026-09-16]})

      assert sync!(h).updated == 1
      assert requests(fake) == [@post, @patch]
      [transaction] = FakeYnab.live(fake)

      assert {transaction.amount, transaction.date, transaction.payee_name} ==
               {-50_000, "2026-09-16", "Einkauf groß"}

      assert String.starts_with?(transaction.memo, "Gesamt 100,00 €")
    end

    test "deletes the transaction of a deleted expense and forgets it", %{h: h, fake: fake} do
      connect(h)
      id = create(shared(h, "Einkauf", 8400, "2026-09-15"))
      sync!(h)
      [%{id: transaction_id}] = FakeYnab.live(fake)

      delete(h, id)
      assert sync!(h).deleted == 1

      assert List.last(requests(fake)) == "DELETE #{@transactions}/#{transaction_id}"
      assert FakeYnab.live(fake) == []
      assert rows(h) == %{}
    end

    test "remembers the result of the last sync in the status", %{h: h} do
      connect(h)
      create(shared(h, "Einkauf", 8400, "2026-09-15"))
      sync!(h)

      assert {status(h).last_synced_at, status(h).error, status(h).summary} ==
               {@now, nil, "1 neu · 0 geändert · 0 gelöscht"}
    end

    test "bundles all changes of one kind into a single request", %{h: h, fake: fake} do
      connect(h)
      for i <- 0..4, do: create(shared(h, "Ausgabe #{i}", 1000, "2026-09-1#{i}"))
      assert sync!(h).created == 5
      assert requests(fake) == [@post]

      {:ok, _renamed} =
        Participants.rename_participant(nil, Participants.get_participant!(h.anna), %{
          name: "Änna"
        })

      assert sync!(h).updated == 5
      assert requests(fake) == [@patch]
      assert Enum.all?(FakeYnab.live(fake), &String.contains?(&1.memo, "bezahlt von Änna"))
    end

    test "writes the original currency into the memo", %{h: h, fake: fake} do
      connect(h)

      id =
        create(
          foreign(h, "Diner in NYC", 9000, "USD", 1.125, "2026-09-20", h.cleo, [h.anna, h.cleo])
        )

      sync!(h)

      [transaction] = FakeYnab.live(fake)
      assert transaction.memo == "Gesamt 80,00 € (90,00 USD) · bezahlt von Cleo · #{marker(id)}"
      assert transaction.amount == -40_000
    end

    test "keeps a category set by hand in YNAB while the app category is not mapped",
         %{h: h, fake: fake} do
      connect(h)
      id = create(shared(h, "Pizza", 3000, "2026-09-20"))
      sync!(h)
      [%{id: transaction_id}] = FakeYnab.live(fake)
      FakeYnab.change(fake, transaction_id, &%{&1 | category_id: "c-out"})
      edit(h, id, &%{&1 | title: "Pizza Napoli"})

      sync!(h)
      assert [%{category_id: "c-out", payee_name: "Pizza Napoli"}] = FakeYnab.live(fake)

      {:ok, _changed} = Connections.put_category_mapping(h.anna, %{h.food => "c-food"}, %{})
      assert sync!(h).updated == 1
      assert [%{category_id: "c-food"}] = FakeYnab.live(fake)
    end
  end

  describe "selecting the expenses entered before the setup" do
    @entered ~U[2026-09-20 10:00:00Z]

    setup %{h: h} do
      connect(h, start: "2026-09-10", at: ~U[2026-09-21 10:00:00Z])
      :ok
    end

    test "takes only the person's shares of expenses from the start date on", %{h: h, fake: fake} do
      create(shared(h, "Vor dem Start", 1000, "2026-09-01"), @entered)
      ok = create(shared(h, "Passt", 2000, "2026-09-15"), @entered)
      create(equal(h, "Ohne Anna", 3000, "2026-09-15", h.anna, [h.ben, h.cleo]), @entered)
      create(equal(h, "Ben und Cleo", 3000, "2026-09-15", h.ben, [h.ben, h.cleo]), @entered)
      create(shared(h, "Zukunft", 4000, "2026-10-05"), @entered)
      create(reimbursement(1500, "2026-09-20", h.ben, h.anna), @entered)
      gone = create(shared(h, "Gelöscht", 5000, "2026-09-16"), @entered)
      delete(h, gone)

      assert sync!(h).created == 1

      assert Enum.map(FakeYnab.live(fake), & &1.memo)
             |> Enum.map(&List.last(String.split(&1, "#"))) == ["#{ok}"]
    end

    test "adds an earlier expense when the start date moves back", %{h: h, fake: fake} do
      create(shared(h, "Vor dem Start", 1000, "2026-09-01"), @entered)
      create(shared(h, "Passt", 2000, "2026-09-15"), @entered)
      sync!(h)
      retarget(h, FakeYnab.account(), "2026-09-01")

      assert sync!(h).created == 1
      assert length(FakeYnab.live(fake)) == 2
    end

    test "keeps transferred transactions when the start date moves forward", %{h: h, fake: fake} do
      early = create(shared(h, "Früh", 1000, "2026-09-12"), @entered)
      sync!(h)
      retarget(h, FakeYnab.account(), "2026-09-16")

      assert sync!(h).deleted == 0
      assert length(FakeYnab.live(fake)) == 1
      assert Map.has_key?(rows(h), early)
    end

    test "adds a future expense once it is due", %{h: h, fake: fake} do
      create(shared(h, "Zukunft", 4000, "2026-10-05"), @entered)
      assert sync!(h).created == 0

      assert sync!(h, full: true, now: DateTime.add(@now, 3, :day)).created == 1
      assert Enum.map(FakeYnab.live(fake), & &1.date) == ["2026-10-05"]
    end

    test "deletes the transaction when the person no longer has a share", %{h: h, fake: fake} do
      id = create(shared(h, "Gemeinsam", 4000, "2026-09-15"), @entered)
      sync!(h)
      edit(h, id, &%{&1 | parts: [%{participant_id: h.ben, weight: 0}]})

      assert sync!(h).deleted == 1
      assert FakeYnab.live(fake) == []
    end

    test "syncs a backdated expense entered after connecting", %{h: h, fake: fake} do
      late = create(shared(h, "Nachgetragen", 2000, "2026-09-05"), ~U[2026-09-22 10:00:00Z])

      assert sync!(h).created == 1
      assert [%{date: "2026-09-05", memo: memo}] = FakeYnab.live(fake)
      assert String.ends_with?(memo, marker(late))
    end

    test "treats a change of the account as a new setup that only looks at the start date", %{
      h: h
    } do
      create(shared(h, "Nachgetragen", 2000, "2026-09-05"), ~U[2026-09-22 10:00:00Z])
      sync!(h)

      retarget(h, "acc-giro", "2026-09-10", ~U[2026-09-23 10:00:00Z])
      assert sync!(h).created == 0
    end

    test "keeps an expense that is moved before the start date", %{h: h, fake: fake} do
      id = create(shared(h, "Kino", 2400, "2026-09-15"), @entered)
      sync!(h)
      requests(fake)
      edit(h, id, &%{&1 | date: ~D[2026-09-01]})

      result = sync!(h, full: true)

      assert {result.updated, result.deleted} == {1, 0}
      assert requests(fake) == [@patch]
      assert Enum.map(FakeYnab.live(fake), & &1.date) == ["2026-09-01"]
    end
  end

  describe "when YNAB does not answer clearly" do
    test "does not create a transaction twice when the answer to its creation got lost",
         %{h: h, fake: fake} do
      connect(h)
      id = create(shared(h, "Kino", 2400, "2026-09-20"))
      FakeYnab.lose_post(fake)
      outcome = sync(h)
      assert Error.kind(outcome.error) == :unclear
      assert rows(h)[id].state == :pending
      assert status(h).retry_at == later(5)

      requests(fake)
      sync!(h, now: later(6))

      assert requests(fake) == [@list_shared, @patch]
      assert [%{id: transaction_id}] = FakeYnab.live(fake)
      assert {rows(h)[id].ynab_transaction_id, rows(h)[id].state} == {transaction_id, :synced}
    end

    test "searches a lost creation regardless of the date of its expense", %{h: h, fake: fake} do
      connect(h, start: "2026-09-10", at: ~U[2026-09-20 10:00:00Z])
      id = create(shared(h, "Nachgetragen", 2000, "2026-09-05"), ~U[2026-09-21 10:00:00Z])
      FakeYnab.lose_post(fake)
      assert Error.kind(sync(h).error) == :unclear
      requests(fake)

      sync!(h, now: later(6))

      assert requests(fake) == [@list_shared, @patch]
      assert [%{date: "2026-09-05", id: transaction_id}] = FakeYnab.live(fake)
      assert rows(h)[id].ynab_transaction_id == transaction_id
    end

    test "deletes the transaction of an expense deleted while its creation was unclear",
         %{h: h, fake: fake} do
      connect(h)
      id = create(shared(h, "Kino", 2400, "2026-09-20"))
      FakeYnab.lose_post(fake)
      sync(h)
      [%{id: created}] = FakeYnab.live(fake)
      delete(h, id)
      requests(fake)

      sync!(h, now: later(6))

      assert requests(fake) == [@list_shared, "DELETE #{@transactions}/#{created}"]
      assert FakeYnab.live(fake) == []
    end

    test "finds a transaction of unclear outcome after its date moved", %{h: h, fake: fake} do
      connect(h, start: "2026-09-10", at: ~U[2026-09-20 10:00:00Z])
      id = create(shared(h, "Nachgetragen", 2000, "2026-09-05"), ~U[2026-09-21 10:00:00Z])
      FakeYnab.lose_post(fake)
      sync(h)
      edit(h, id, &%{&1 | date: ~D[2026-09-20]})

      sync!(h, now: later(6))

      assert [%{date: "2026-09-20", id: transaction_id}] = FakeYnab.live(fake)
      assert rows(h)[id].ynab_transaction_id == transaction_id
    end

    test "treats an answer without data as an unclear outcome, never as an empty list",
         %{h: h, fake: fake} do
      connect(h)
      id = create(shared(h, "Kino", 2400, "2026-09-20"))
      FakeYnab.lose_post(fake)
      sync(h)
      FakeYnab.bare_list(fake, true)
      requests(fake)

      assert Error.kind(sync(h, now: later(6)).error) == :unclear
      assert requests(fake) == [@list_shared]
      assert length(FakeYnab.live(fake)) == 1
      assert rows(h)[id].state == :pending

      FakeYnab.bare_list(fake, false)
      sync!(h, now: later(12))
      assert length(FakeYnab.live(fake)) == 1
    end

    test "creates a transaction again that YNAB returns as deleted", %{h: h, fake: fake} do
      connect(h)
      id = create(shared(h, "A", 1000, "2026-09-20"))
      sync!(h)
      FakeYnab.change(fake, rows(h)[id].ynab_transaction_id, &%{&1 | deleted: true})
      edit(h, id, &%{&1 | title: "A2"})

      assert sync!(h).again
      sync!(h)
      assert Enum.map(FakeYnab.live(fake), & &1.payee_name) == ["A2"]
    end

    test "creates a transaction again that YNAB does not know any more", %{h: h, fake: fake} do
      connect(h)
      id = create(shared(h, "B", 2000, "2026-09-21"))
      sync!(h)
      FakeYnab.forget(fake, rows(h)[id].ynab_transaction_id)
      edit(h, id, &%{&1 | title: "B2"})

      assert sync!(h).again
      sync!(h)
      assert Enum.map(FakeYnab.live(fake), & &1.payee_name) == ["B2"]
    end
  end

  describe "when YNAB refuses" do
    test "backs off after a rate limit and sends nothing during the pause", %{h: h, fake: fake} do
      connect(h)
      id = create(shared(h, "Kino", 2400, "2026-09-20"))
      FakeYnab.fail(fake, 429)

      assert Error.kind(sync(h).error) == :rate_limited
      assert requests(fake) == [@post]
      assert {status(h).retry_at, status(h).backoff_seconds} == {later(5), 300}
      assert status(h).error =~ "Anfragelimit"
      assert {rows(h)[id].state, rows(h)[id].ynab_transaction_id} == {:unknown, nil}

      assert sync(h).skipped == :backed_off
      assert requests(fake) == []
    end

    test "waits as long as YNAB's Retry-After asks when that is longer", %{h: h, fake: fake} do
      connect(h)
      create(shared(h, "Kino", 2400, "2026-09-20"))
      FakeYnab.fail(fake, {429, 1800})

      assert sync(h).error.retry_after == 1800
      assert {status(h).retry_at, status(h).backoff_seconds} == {later(30), 300}
      at = later(30) |> LocalTime.from_utc() |> Calendar.strftime("%H:%M")

      assert status(h).error ==
               "Das YNAB-Anfragelimit ist erreicht. Nächster Versuch um #{at} Uhr."
    end

    test "doubles the pause on every further rate limit and resets it after a success",
         %{h: h, fake: fake} do
      connect(h)
      create(shared(h, "Kino", 2400, "2026-09-20"))
      FakeYnab.fail(fake, 429)
      sync(h)
      FakeYnab.fail(fake, 429)
      sync(h, now: later(6))
      assert status(h).backoff_seconds == 600

      assert sync!(h, now: later(17)).created == 1
      assert {status(h).error, status(h).backoff_seconds, status(h).retry_at} == {nil, 0, nil}
    end

    test "schedules the next run for the end of the pause", %{h: h, fake: fake} do
      connect(h)
      id = create(shared(h, "Kino", 2400, "2026-09-20"))
      sync!(h)
      FakeYnab.fail(fake, 429)
      edit(h, id, &%{&1 | title: "Kino 2"})

      next_run = Sync.sync_all(false, now: @now, debounce: 5000)

      assert next_run >= :timer.minutes(5)
      assert next_run <= :timer.minutes(5) + 1000
    end

    test "records a failure to date an older connection, without the token", %{h: h} do
      connect(h)
      Repo.update_all(Zipfelkasse.Ynab.Connection, set: [connected_at: nil])

      Repo.query!("""
      CREATE TRIGGER fail_connected_at BEFORE UPDATE OF connected_at ON ynab_connections
      BEGIN SELECT RAISE(ABORT, 'kaputt #{FakeYnab.token()}'); END
      """)

      assert sync(h).message =~ "kaputt •••"
      assert status(h).error =~ "kaputt •••"
      refute status(h).error =~ FakeYnab.token()
      assert status(h).last_run_at == @now
    end

    test "stops syncing with an invalid token until a new one is saved", %{h: h, fake: fake} do
      connect(h)
      {:ok, false} = Connections.put_token(h.anna, "wrong")
      create(shared(h, "Kino", 2400, "2026-09-20"))

      assert Error.kind(sync(h).error) == :unauthorized
      assert status(h).token_invalid
      assert status(h).error =~ "Token"
      requests(fake)
      assert sync(h, full: true).skipped == :token_invalid
      assert requests(fake) == []

      {:ok, false} = Connections.put_token(h.anna, FakeYnab.token())
      assert sync!(h).created == 1
    end

    test "records a rejected transaction after trying the batch and each one on its own, " <>
           "and retries it only in the full sync",
         %{h: h, fake: fake} do
      connect(h)
      good = create(shared(h, "Gut", 1000, "2026-09-20"))
      bad = create(shared(h, "REJECT", 2000, "2026-09-21"))

      result = sync!(h)
      assert {result.created, result.failed} == {1, 1}
      assert requests(fake) == [@post, @post, @post]
      assert rows(h)[good].ynab_transaction_id
      refute rows(h)[bad].ynab_transaction_id
      assert rows(h)[bad].last_error =~ "payee rejected"

      sync!(h)
      assert requests(fake) == []
      sync!(h, full: true)
      assert requests(fake) == [@post, @post]
      assert Enum.map(elem(Transactions.summary(h.anna), 1), & &1.title) == ["REJECT"]
    end

    test "after three single failures in a row the rest waits for the full sync", %{
      h: h,
      fake: fake
    } do
      connect(h)
      for i <- 1..5, do: create(shared(h, "REJECT #{i}", 1000, "2026-09-2#{i}"))

      result = sync!(h)

      assert {result.created, result.failed} == {0, 5}
      assert requests(fake) == [@post, @post, @post, @post]
      assert Enum.all?(Map.values(rows(h)), &(&1.state == :failed))
    end

    test "deletes right away what a failed batch and a failed single update could not change",
         %{h: h, fake: fake} do
      connect(h)
      id = create(shared(h, "Kino", 2400, "2026-09-20"))
      sync!(h)
      edit(h, id, &%{&1 | title: "Kino 2"})
      FakeYnab.fail(fake, [400, 400])

      assert sync!(h).failed == 1
      assert rows(h)[id].ynab_transaction_id
      assert rows(h)[id].last_error

      delete(h, id)
      assert sync!(h).deleted == 1
      assert FakeYnab.live(fake) == []
    end

    test "retries a failed deletion only in the full sync", %{h: h, fake: fake} do
      connect(h)
      id = create(shared(h, "Kino", 2400, "2026-09-20"))
      sync!(h)
      [%{id: transaction_id}] = FakeYnab.live(fake)
      deletion = "DELETE #{@transactions}/#{transaction_id}"
      delete(h, id)
      requests(fake)
      FakeYnab.fail(fake, 400)

      assert sync!(h).failed == 1
      assert requests(fake) == [deletion]

      assert {rows(h)[id].state, rows(h)[id].ynab_transaction_id} ==
               {:delete_failed, transaction_id}

      create(shared(h, "Pizza", 3000, "2026-09-21"))
      result = sync!(h)
      assert {result.created, result.failed + result.deleted} == {1, 0}
      assert requests(fake) == [@post]
      assert sync!(h, full: true).deleted == 1
      assert requests(fake) == [deletion]
    end

    test "stops the run when plan or account are not accessible", %{h: h, fake: fake} do
      connect(h)
      a = create(shared(h, "A", 1000, "2026-09-20"))
      b = create(shared(h, "B", 2000, "2026-09-21"))
      sync!(h)
      before = Map.new(rows(h), fn {id, row} -> {id, row.ynab_transaction_id} end)
      {:ok, false} = Connections.put_token(h.anna, FakeYnab.other_token())

      delete(h, b)
      assert Error.kind(sync(h).error) == :not_found
      assert status(h).error =~ "Plan oder Konto"
      edit(h, a, &%{&1 | title: "A2"})
      assert Error.kind(sync(h).error) == :not_found
      assert Map.new(rows(h), fn {id, row} -> {id, row.ynab_transaction_id} end) == before

      {:ok, false} = Connections.put_token(h.anna, FakeYnab.token())
      result = sync!(h)
      assert {result.updated, result.deleted, result.created} == {1, 1, 0}
      assert Enum.map(FakeYnab.live(fake), & &1.payee_name) == ["A2"]
    end

    test "redacts the token from errors", %{h: h, fake: fake} do
      connect(h)
      create(shared(h, "Kino", 2400, "2026-09-20"))
      FakeYnab.fail(fake, 503)

      assert sync(h).error
      refute status(h).error =~ FakeYnab.token()
      assert status(h).error == "YNAB-Fehler 503: Error 503 with •••"
    end
  end

  describe "changing the account" do
    test "looks for the transactions in the new account", %{h: h, fake: fake} do
      connect(h)
      create(shared(h, "Kino", 2400, "2026-09-20"))
      sync!(h)
      retarget(h, "acc-giro", "2026-09-01")

      assert Enum.all?(
               Map.values(rows(h)),
               &(&1.ynab_transaction_id == nil and &1.state == :retarget)
             )

      requests(fake)

      assert sync!(h).created == 1
      assert requests(fake) == [@list_giro, @post]
    end

    test "does not duplicate transactions when switching the account and back", %{
      h: h,
      fake: fake
    } do
      connect(h)
      a = create(shared(h, "A", 1000, "2026-09-20"))
      b = create(shared(h, "B", 2000, "2026-09-21"))
      gone = create(shared(h, "Weg", 3000, "2026-09-22"))
      sync!(h)
      in_shared = rows(h)

      retarget(h, "acc-giro", "2026-09-01")
      assert sync!(h).created == 3
      edit(h, a, &%{&1 | title: "A2"})
      delete(h, gone)
      sync!(h)

      retarget(h, FakeYnab.account(), "2026-09-01")
      requests(fake)
      result = sync!(h)

      assert {result.created, result.updated, result.deleted} == {0, 2, 0}
      assert requests(fake) == [@list_shared, @patch]
      assert rows(h)[a].ynab_transaction_id == in_shared[a].ynab_transaction_id
      assert rows(h)[b].ynab_transaction_id == in_shared[b].ynab_transaction_id
      refute Map.has_key?(rows(h), gone)

      assert fake
             |> FakeYnab.live()
             |> Enum.filter(&(&1.account_id == "acc-geteilt"))
             |> Enum.map(& &1.payee_name) ==
               ["A2", "B", "Weg"]

      assert sync!(h) == %Result{}
    end
  end

  describe "the scheduler" do
    defp start_scheduler(opts \\ []),
      do: start_supervised!({Scheduler, Keyword.merge([start_delay: :timer.hours(1)], opts)})

    defp hang_a_sync(h, fake) do
      FakeYnab.hold(fake)
      requests(fake)
      Scheduler.sync_now(h.anna)
      eventually(fn -> FakeYnab.request_count(fake) > 0 end)
    end

    test "waits for a running sync before changing the account", %{h: h, fake: fake} do
      connect(h)
      id = create(shared(h, "Kino", 2400, "2026-09-20"))
      start_scheduler()
      hang_a_sync(h, fake)

      change =
        Task.async(fn ->
          Scheduler.change_connection(fn -> retarget(h, "acc-giro", "2026-09-01") end)
        end)

      refute Task.yield(change, 100)
      FakeYnab.release(fake)
      Task.await(change)

      assert rows(h)[id].ynab_transaction_id == nil
      sync!(h)

      [transaction] =
        Enum.filter(FakeYnab.live(fake), &(&1.id == rows(h)[id].ynab_transaction_id))

      assert transaction.account_id == "acc-giro"
    end

    test "keeps a new token that is saved during a sync valid", %{h: h, fake: fake} do
      connect(h)
      {:ok, false} = Connections.put_token(h.anna, "expired")
      create(shared(h, "Kino", 2400, "2026-09-20"))
      start_scheduler()
      hang_a_sync(h, fake)

      change =
        Task.async(fn ->
          Scheduler.change_connection(fn -> Connections.put_token(h.anna, FakeYnab.token()) end)
        end)

      refute Task.yield(change, 100)
      FakeYnab.release(fake)
      Task.await(change)

      assert {status(h).token_invalid, status(h).error} == {false, nil}
      assert sync!(h).created == 1
    end

    test "a stopped sync leaves no error and no pause for the next start", %{h: h, fake: fake} do
      connect(h)
      create(shared(h, "Kino", 2400, "2026-09-20"))
      FakeYnab.hold(fake)
      start_scheduler(start_delay: 1)
      eventually(fn -> FakeYnab.request_count(fake) > 0 end)

      {elapsed, :ok} = :timer.tc(fn -> stop_supervised(Scheduler) end, :millisecond)
      FakeYnab.release(fake)

      assert elapsed < 2000
      assert {status(h).error, status(h).retry_at} == {nil, nil}
      assert Enum.map(Map.values(rows(h)), & &1.state) == [:pending]
    end

    test "answers a manual sync without waiting for YNAB", %{h: h, fake: fake} do
      connect(h)
      create(shared(h, "Kino", 2400, "2026-09-20"))
      start_scheduler()
      FakeYnab.hold(fake)

      {elapsed, {:ok, _message}} =
        :timer.tc(fn -> Zipfelkasse.Ynab.sync_now(h.anna) end, :millisecond)

      assert elapsed < 1000

      FakeYnab.release(fake)
      eventually(fn -> length(FakeYnab.live(fake)) == 1 end)
    end

    test "never blocks when it is triggered" do
      start_scheduler()

      {elapsed, _ok} =
        :timer.tc(fn -> for _ <- 1..10_000, do: Scheduler.trigger() end, :millisecond)

      assert elapsed < 2000
    end

    test "syncs shortly after a change", %{h: h, fake: fake} do
      connect(h)
      start_scheduler(debounce: 10)

      create(shared(h, "Kino", 2400, "2026-09-20"))
      eventually(fn -> FakeYnab.live(fake) != [] end)
    end

    test "runs a connection change in the caller when it is off and passes errors on" do
      assert Scheduler.change_connection(fn -> :done end) == :done
      start_scheduler()
      assert Scheduler.change_connection(fn -> :done end) == :done

      assert_raise RuntimeError, "broken", fn ->
        Scheduler.change_connection(fn -> raise "broken" end)
      end
    end
  end

  test "logs a manual sync without the token, and an invalid token only once", %{h: h, fake: fake} do
    connect(h)
    create(shared(h, "Kino", 2400, "2026-09-20"))
    FakeYnab.fail(fake, 503)

    log = capture_log(fn -> Sync.sync_person(h.anna, true, manual: true, now: @now) end)
    assert log =~ "YNAB sync (now) failed"
    refute log =~ FakeYnab.token()
    assert log =~ "•••"

    {:ok, false} = Connections.put_token(h.anna, "expired")
    capture_log(fn -> Sync.sync_person(h.anna, true, manual: true, now: later(6)) end)

    refute capture_log(fn -> Sync.sync_person(h.anna, true, manual: true, now: later(7)) end) =~
             "failed"
  end

  test "an archived category keeps its mapping", %{h: h} do
    connect(h)
    {:ok, _archived} = Categories.archive_category(nil, Categories.get_category!(h.food))
    {:ok, _changed} = Connections.put_category_mapping(h.anna, %{h.food => "c-food"}, %{})

    assert Connections.category_mapping(h.anna) == %{h.food => "c-food"}
  end
end
