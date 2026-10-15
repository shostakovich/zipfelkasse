defmodule Zipfelkasse.Fx.RefreshJobTest do
  use ExUnit.Case, async: true

  alias Zipfelkasse.Fx.RefreshJob

  for {newest, now, due} <- [
        {nil, "2026-10-02 12:00:00", true},
        {"2026-10-01", "2026-10-02 12:00:00", false},
        {"2026-10-01", "2026-10-02 16:59:00", false},
        {"2026-10-01", "2026-10-02 17:00:00", true},
        {"2026-10-02", "2026-10-03 16:59:00", false},
        {"2026-09-30", "2026-10-02 12:00:00", true}
      ] do
    test "with the newest day #{inspect(newest)} at #{now} a refresh is due: #{due}" do
      newest = unquote(newest) && Date.from_iso8601!(unquote(newest))

      assert RefreshJob.due?(newest, NaiveDateTime.from_iso8601!(unquote(now))) == unquote(due)
    end
  end
end
