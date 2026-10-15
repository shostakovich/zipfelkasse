defmodule Zipfelkasse.DailyJobTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Zipfelkasse.{DailyJob, LocalTime}

  defp start(run, at_boot?) do
    start_supervised!(
      {DailyJob,
       name: :"job_#{System.unique_integer([:positive])}",
       at: ~T[03:00:00],
       run: run,
       at_boot?: at_boot?}
    )
  end

  test "runs at boot when a run is missing" do
    test = self()
    start(fn -> send(test, :ran) end, fn -> true end)

    assert_receive :ran
  end

  test "waits for its time otherwise" do
    test = self()
    start(fn -> send(test, :ran) end, fn -> false end)

    refute_receive :ran, 50
  end

  test "plans the next day when the timer fires a moment before its time" do
    test = self()
    job = start(fn -> send(test, :ran) end, fn -> false end)
    %{due: due} = :sys.get_state(job)
    assert NaiveDateTime.after?(due, LocalTime.now())

    send(job, :run)

    assert_receive :ran
    assert :sys.get_state(job).due == NaiveDateTime.add(due, 1, :day)
  end

  test "logs a failed run and goes on" do
    log =
      capture_log(fn ->
        job = start(fn -> {:error, "no connection"} end, fn -> true end)
        :sys.get_state(job)
        job = start(fn -> raise "boom" end, fn -> true end)
        :sys.get_state(job)
        assert Process.alive?(job)
      end)

    assert log =~ "failed: no connection"
    assert log =~ "boom"
  end
end
