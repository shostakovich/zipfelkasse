defmodule Zipfelkasse.Ynab.Scheduler do
  @moduledoc """
  Runs the YNAB syncs, one at a time: after the start, shortly after an expense changed
  (debounced), every hour in full, and when a person asks. Changes of a connection run here too,
  so that no sync works with a token or target that changes meanwhile; while it is not running
  (tests), they run in the caller.

  Options: `:debounce` (5 s), `:start_delay` (15 s).
  """

  use GenServer

  alias Zipfelkasse.Expenses
  alias Zipfelkasse.Ynab.Sync

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Asks for a sync soon; never blocks."
  def trigger, do: cast(:trigger)

  @doc "Starts a full sync of a person in the background."
  def sync_now(participant_id), do: cast({:sync_now, participant_id})

  defp cast(message) do
    if pid = GenServer.whereis(__MODULE__), do: GenServer.cast(pid, message)
    :ok
  end

  @doc "Runs `fun` between syncs and returns its result; it waits for a running sync."
  def change_connection(fun) do
    case GenServer.whereis(__MODULE__) do
      nil ->
        fun.()

      pid ->
        case GenServer.call(pid, {:change, fun}, :infinity) do
          {:ok, result} -> result
          {:raised, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
        end
    end
  end

  @impl true
  def init(opts) do
    Expenses.subscribe()

    state = %{
      debounce: Keyword.get(opts, :debounce, :timer.seconds(5)),
      timer: nil,
      deadline: nil,
      last_full: nil,
      manual: MapSet.new()
    }

    {:ok, schedule(state, Keyword.get(opts, :start_delay, :timer.seconds(15)))}
  end

  @impl true
  def handle_cast(:trigger, state), do: {:noreply, soon(state)}

  def handle_cast({:sync_now, participant_id}, state) do
    if MapSet.member?(state.manual, participant_id) do
      {:noreply, state}
    else
      send(self(), {:sync_now, participant_id})
      {:noreply, %{state | manual: MapSet.put(state.manual, participant_id)}}
    end
  end

  @impl true
  def handle_call({:change, fun}, _from, state) do
    reply =
      try do
        {:ok, fun.()}
      catch
        kind, reason -> {:raised, kind, reason, __STACKTRACE__}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info({:expenses_changed, _ids}, state), do: {:noreply, soon(state)}

  def handle_info({:run, id}, %{timer: {id, _timer}} = state) do
    now = System.monotonic_time(:millisecond)
    # A minute early, so the hourly run is full even when a debounced run moved it.
    full? =
      is_nil(state.last_full) or now - state.last_full >= Sync.full_interval() - :timer.minutes(1)

    next_run = Sync.sync_all(full?, debounce: state.debounce)
    state = if full?, do: %{state | last_full: now}, else: state
    {:noreply, schedule(state, next_run)}
  end

  def handle_info({:run, _stale}, state), do: {:noreply, state}

  def handle_info({:sync_now, participant_id}, state) do
    Sync.sync_person(participant_id, true, manual: true)
    {:noreply, %{state | manual: MapSet.delete(state.manual, participant_id)}}
  end

  defp soon(state) do
    if state.deadline - System.monotonic_time(:millisecond) > state.debounce,
      do: schedule(state, state.debounce),
      else: state
  end

  defp schedule(state, delay) do
    with {_id, timer} <- state.timer, do: Process.cancel_timer(timer)
    id = make_ref()
    timer = Process.send_after(self(), {:run, id}, delay)
    %{state | timer: {id, timer}, deadline: System.monotonic_time(:millisecond) + delay}
  end
end
