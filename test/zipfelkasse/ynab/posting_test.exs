defmodule Zipfelkasse.Ynab.PostingTest do
  use ExUnit.Case, async: true

  alias Zipfelkasse.Expenses.{Expense, ExpenseShare}
  alias Zipfelkasse.Participants.Participant
  alias Zipfelkasse.Ynab
  alias Zipfelkasse.Ynab.{Posting, Selection, Want}

  defp expense(id, fields \\ []) do
    struct(
      %Expense{
        id: id,
        title: "Kino",
        date: ~D[2026-09-01],
        paid_by_id: 1,
        paid_by: %Participant{id: 1, name: "Anna"},
        amount_cents: 1000,
        original_amount: 1000,
        shares: [
          %ExpenseShare{participant_id: 1, amount_cents: 500},
          %ExpenseShare{participant_id: 2, amount_cents: 500}
        ],
        inserted_at: ~U[2026-01-01 00:00:00Z]
      },
      fields
    )
  end

  describe "the posting of an expense" do
    test "takes the person's share as the amount and describes the whole expense in the memo" do
      posting = Posting.from_expense(expense(7), 1)

      assert {posting.amount_cents, posting.payee, posting.memo} ==
               {500, "Kino", "Gesamt 10,00 € · bezahlt von Anna · zipfelkasse #7"}

      assert Posting.milliunits(posting) == -5000
    end

    test "names the original amount of a foreign expense" do
      posting =
        Posting.from_expense(
          expense(3,
            original_currency: "USD",
            original_amount: 9000,
            fx_rate: 1.125,
            amount_cents: 8000
          ),
          1
        )

      assert posting.memo == "Gesamt 80,00 € (90,00 USD) · bezahlt von Anna · zipfelkasse #3"
    end

    test "cuts a long title to the length YNAB accepts" do
      payee = Posting.from_expense(expense(7, title: String.duplicate("x", 250)), 1).payee
      assert length(String.codepoints(payee)) == 200
      assert String.ends_with?(payee, "…")
    end

    test "cuts a long memo before the marker" do
      memo =
        Posting.from_expense(
          expense(7, paid_by: %Participant{name: String.duplicate("ä", 600)}),
          1
        ).memo

      assert length(String.codepoints(memo)) == 500
      assert String.ends_with?(memo, "ä… · zipfelkasse #7")
    end

    test "makes none for a person without a share, a reimbursement or a deleted expense" do
      assert Posting.from_expense(expense(7), 3) == nil
      assert Posting.from_expense(expense(7, reimbursement: true), 1) == nil
      assert Posting.from_expense(expense(7, deleted_at: ~U[2026-09-02 00:00:00Z]), 1) == nil
    end
  end

  for {memo, id} <- [
        {"bla · zipfelkasse #123", 123},
        {"zipfelkasse #12\n", 12},
        {"zipfelkasse #12 und mehr", nil},
        {"zipfelkasse #١٢", nil}
      ] do
    test "finds #{inspect(id)} in #{inspect(memo)}" do
      assert Posting.marker_id(unquote(memo)) == unquote(id)
    end
  end

  test "truncates to the length with an ellipsis" do
    assert Posting.truncate("abcd", 3) == "ab…"
    assert Posting.truncate("abc", 3) == "abc"
    assert Posting.truncate("abc", 1) == "a"
  end

  test "has a fingerprint that never changes, because stored ones are compared with it" do
    posting = %Posting{
      expense_id: 7,
      date: ~D[2026-09-01],
      amount_cents: 500,
      payee: "Kino",
      memo: "memo",
      category_id: 0
    }

    assert Want.new(posting, "c-food").fingerprint == "d4a1ad6e19cee680676eefc66df39514"
  end

  test "YNAB's today is the local date, but never later than the date in UTC" do
    assert Ynab.today(~U[2026-10-02 12:00:00Z], ~D[2026-10-02]) == ~D[2026-10-02]
    assert Ynab.today(~U[2026-10-02 23:30:00Z], ~D[2026-10-03]) == ~D[2026-10-02]
    assert Ynab.today(~U[2026-10-03 03:00:00Z], ~D[2026-10-02]) == ~D[2026-10-02]
  end

  test "redacts the token" do
    assert Ynab.redact("Error with abc and abc", "abc") == "Error with ••• and •••"
    assert Ynab.redact("Error", nil) == "Error"
  end

  describe "the selection" do
    @today ~D[2026-10-02]
    @start ~D[2026-09-10]
    @connected_at ~U[2026-09-20 10:00:00Z]

    defp includes?(selection, date, created) do
      expense =
        expense(7,
          date: date,
          inserted_at: created,
          shares: [%ExpenseShare{participant_id: 1, amount_cents: 500}]
        )

      Selection.includes?(selection, expense, Posting.from_expense(expense, 1))
    end

    test "takes every past expense while YNAB is not set up" do
      assert includes?(%Selection{today: @today}, ~D[2020-01-01], ~U[2020-01-01 10:00:00Z])
    end

    test "leaves out expenses dated after today, which YNAB would reject" do
      refute includes?(%Selection{today: @today}, ~D[2026-10-03], ~U[2026-09-01 10:00:00Z])
    end

    test "takes expenses dated on or after the start date" do
      selection = %Selection{today: @today, start: @start, connected_at: @connected_at}
      assert includes?(selection, ~D[2026-09-10], ~U[2026-09-01 10:00:00Z])
      refute includes?(selection, ~D[2026-09-09], ~U[2026-09-01 10:00:00Z])
    end

    test "takes an expense dated before the start date that was entered after the setup" do
      selection = %Selection{today: @today, start: @start, connected_at: @connected_at}
      assert includes?(selection, ~D[2026-09-01], ~U[2026-09-20 10:00:00Z])
      refute includes?(selection, ~D[2026-09-01], ~U[2026-09-20 09:59:00Z])
    end

    test "keeps an expense dated before the start date that is already in YNAB" do
      selection = %Selection{
        today: @today,
        start: @start,
        connected_at: @connected_at,
        in_ynab: MapSet.new([7])
      }

      assert includes?(selection, ~D[2026-09-01], ~U[2026-09-01 10:00:00Z])
    end
  end
end
