defmodule Zipfelkasse.Fx.RefreshJob do
  @moduledoc """
  Loads the newest ECB rates every day at 17:00 local time, an hour after their publication,
  and at boot when the last of these loads is missing.
  """

  alias Zipfelkasse.{DailyJob, Fx, LocalTime}

  @at ~T[17:00:00]

  def child_spec(_opts) do
    DailyJob.child_spec(name: __MODULE__, at: @at, run: &Fx.refresh/0, at_boot?: &due?/0)
  end

  defp due? do
    range = Fx.ecb_range()
    due?(range && range.last, LocalTime.now())
  end

  @doc "Whether the newest ECB day is older than the day 17 hours before `now` (local time)."
  @spec due?(Date.t() | nil, NaiveDateTime.t()) :: boolean()
  def due?(nil, _now), do: true

  def due?(newest, now),
    do: Date.before?(newest, NaiveDateTime.to_date(NaiveDateTime.add(now, -@at.hour, :hour)))
end
