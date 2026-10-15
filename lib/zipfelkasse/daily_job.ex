defmodule Zipfelkasse.DailyJob do
  @moduledoc """
  Runs a function every day at a local time, and once at boot when `:at_boot?` says a run is
  missing. A failed run is logged; the next one comes the next day.

  Options: `:name`, `:at` (a `Time`), `:run` and `:at_boot?` (functions without arguments).
  """

  use GenServer

  require Logger

  alias Zipfelkasse.LocalTime

  def child_spec(opts),
    do: %{id: Keyword.fetch!(opts, :name), start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  @impl true
  def init(opts), do: {:ok, opts |> Map.new() |> Map.put(:due, nil), {:continue, :boot}}

  @impl true
  def handle_continue(:boot, state) do
    if safely(state, Map.get(state, :at_boot?, fn -> false end)) == true do
      send(self(), :run)
      {:noreply, state}
    else
      {:noreply, schedule(state, LocalTime.now())}
    end
  end

  @impl true
  def handle_info(:run, state) do
    # From the start, so a long run keeps its day; from the target, so an early timer runs once.
    started = later(LocalTime.now(), state.due)

    case safely(state, state.run) do
      {:error, reason} -> Logger.error("#{inspect(state.name)} failed: #{reason}")
      _done -> :ok
    end

    {:noreply, schedule(state, started)}
  end

  defp later(now, nil), do: now
  defp later(now, due), do: Enum.max([now, due], NaiveDateTime)

  # A crash would restart the job, which might run again at once.
  defp safely(state, fun) do
    fun.()
  rescue
    error ->
      Logger.error(
        "#{inspect(state.name)} failed: " <> Exception.format(:error, error, __STACKTRACE__)
      )

      :failed
  end

  defp schedule(state, from) do
    due = LocalTime.next_at(from, state.at)
    Process.send_after(self(), :run, LocalTime.ms_until(due))
    %{state | due: due}
  end
end
