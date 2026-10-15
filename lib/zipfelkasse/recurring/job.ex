defmodule Zipfelkasse.Recurring.Job do
  @moduledoc """
  Catches up the recurring expenses every hour, the first time at boot. The runs keep to a fixed
  interval; one that overruns it starts the next right away and drops the missed ones.
  """

  use GenServer

  require Logger

  alias Zipfelkasse.Recurring

  @every :timer.hours(1)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    send(self(), :run)
    {:ok, now() + @every}
  end

  @impl true
  def handle_info(:run, tick) do
    run()
    now = now()
    Process.send_after(self(), :run, max(tick - now, 0))
    {:noreply, next_tick(tick, now, @every)}
  end

  # A crash would restart the job, which would run again at once.
  defp run do
    case Recurring.catch_up() do
      {:ok, 0} ->
        :ok

      {:ok, created} ->
        Logger.info("Recurring expenses created: #{created}")

      {:error, created, errors} ->
        Logger.error(Enum.join(["Recurring expenses created: #{created}" | errors], "\n"))
    end
  rescue
    error ->
      Logger.error(
        "Recurring expenses failed: " <> Exception.format(:error, error, __STACKTRACE__)
      )
  end

  @doc "The first tick of the interval `every` from `tick` that lies after `now`."
  @spec next_tick(integer(), integer(), pos_integer()) :: integer()
  def next_tick(tick, now, every) do
    next = tick + every
    if next > now, do: next, else: next_tick(next, now, every)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
