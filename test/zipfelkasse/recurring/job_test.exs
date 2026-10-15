defmodule Zipfelkasse.Recurring.JobTest do
  use Zipfelkasse.DataCase

  import Zipfelkasse.Fixtures

  alias Zipfelkasse.{Expenses, Recurring}
  alias Zipfelkasse.Recurring.Job

  test "catches up at boot" do
    h = household()

    expense =
      create!(
        equal(h, "Putzen", 4000, Date.to_iso8601(Date.add(Date.utc_today(), -30)), h.anna, [
          h.anna
        ])
      )

    {:ok, rule, 0} = Recurring.create_rule(nil, expense, :weekly, today: expense.date)
    Expenses.subscribe()

    start_supervised!(Job)
    :sys.get_state(Job)

    assert_received {:expenses_changed, _ids}
    refute Date.before?(Recurring.get_rule!(rule.id).next_date, Date.utc_today())
  end

  describe "next_tick/3" do
    test "keeps to the interval" do
      assert Job.next_tick(1000, 1500, 1000) == 2000
      assert Job.next_tick(2000, 2000, 1000) == 3000
    end

    test "drops the ticks an overrunning run missed" do
      assert Job.next_tick(2000, 4500, 1000) == 5000
    end
  end
end
