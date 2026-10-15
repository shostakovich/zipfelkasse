defmodule Zipfelkasse.Fx.Loader do
  @moduledoc """
  Loads ECB rates on demand and owns the state of the downloads. The cache runs without gaps
  from its first to its last day: a date before it loads the file that reaches it, a date after
  it loads the 90-day file only once the ECB can have published since the last load (weekdays at
  16:00 local time). Each file is downloaded at most every 15 minutes; until then a failure's
  error is repeated. Concurrent requests share one download.

  Without a base URL (in tests) nothing is downloaded.
  """

  use GenServer

  require Logger

  alias Zipfelkasse.{Fx, LocalTime}
  alias Zipfelkasse.Fx.Ecb

  @recent_days 85
  @publish_at ~T[16:00:00]
  @cooldown_seconds 15 * 60

  @doc """
  Options: `:name` (nil for none), `:base_url` (from the config by default) and `:clock`, a
  function giving the UTC time.
  """
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "Loads what `date` needs, unless the cache has it; `{:error, message}` when that fails."
  @spec ensure(GenServer.server(), Date.t()) :: :ok | {:error, String.t()}
  def ensure(server \\ __MODULE__, %Date{} = date),
    do: GenServer.call(server, {:ensure, date}, :infinity)

  @doc "Loads the newest rates now and gives the newest day."
  @spec refresh(GenServer.server()) :: {:ok, Date.t()} | {:error, String.t()}
  def refresh(server \\ __MODULE__), do: GenServer.call(server, :refresh, :infinity)

  @impl true
  def init(opts) do
    {:ok,
     %{
       base_url: Keyword.get_lazy(opts, :base_url, &base_url/0),
       clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
       range: :unread,
       fetched_at: nil,
       attempts: %{},
       loads: %{}
     }}
  end

  defp base_url, do: Application.fetch_env!(:zipfelkasse, Ecb)[:base_url]

  @impl true
  def handle_call({:ensure, _date}, _from, %{base_url: nil} = state), do: {:reply, :ok, state}

  def handle_call(:refresh, _from, %{base_url: nil} = state),
    do: {:reply, {:error, Fx.unavailable_message("downloads are off")}, state}

  def handle_call({:ensure, date}, from, state) do
    state = read_range(state)
    utc = state.clock.()
    now = LocalTime.from_utc(utc)

    with file when is_binary(file) <-
           file_to_load(state.range, date, NaiveDateTime.to_date(now), state.fetched_at, now),
         :load <- cooldown(state.attempts[file], utc) do
      {:noreply, load(state, file, {from, :ensure})}
    else
      nil -> {:reply, :ok, state}
      {:cooling_down, nil} -> {:reply, :ok, state}
      {:cooling_down, message} -> {:reply, {:error, message}, state}
    end
  end

  def handle_call(:refresh, from, state) do
    state = read_range(state)
    today = LocalTime.date(state.clock.())
    file = file_reaching(if(state.range, do: state.range.last, else: today), today)
    {:noreply, load(state, file, {from, :refresh})}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case Enum.find(state.loads, fn {_file, load} -> load.ref == ref end) do
      {file, load} ->
        {:noreply, loaded(%{state | loads: Map.delete(state.loads, file)}, file, load, result)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp read_range(%{range: :unread} = state), do: %{state | range: Fx.ecb_range()}
  defp read_range(state), do: state

  defp cooldown(nil, _now), do: :load

  defp cooldown({at, error}, now) do
    if DateTime.diff(now, at) < @cooldown_seconds, do: {:cooling_down, error}, else: :load
  end

  defp load(state, file, waiter) do
    case state.loads do
      %{^file => load} ->
        put_in(state.loads[file], %{load | waiters: [waiter | load.waiters]})

      _none ->
        base_url = state.base_url
        task = Task.async(fn -> download(base_url, file) end)
        put_in(state.loads[file], %{ref: task.ref, waiters: [waiter]})
    end
  end

  defp download(base_url, file) do
    with {:ok, rates} <- Ecb.download(base_url, file),
         :ok <- Fx.save_ecb_rates(rates) do
      {:ok, Enum.min_by(rates, & &1.date, Date).date, Enum.max_by(rates, & &1.date, Date).date,
       length(rates)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, inspect(reason)}
  end

  defp loaded(state, file, load, {:ok, oldest, newest, count}) do
    Logger.info(
      "ECB rates loaded: #{file}, #{count} rates from #{Date.to_iso8601(oldest)} " <>
        "to #{Date.to_iso8601(newest)}"
    )

    utc = state.clock.()
    range = merge(state.range, Date.range(oldest, newest))
    reply(load.waiters, :ok, {:ok, newest})

    %{
      state
      | range: range,
        fetched_at: LocalTime.from_utc(utc),
        attempts: Map.put(state.attempts, file, {utc, nil})
    }
  end

  defp loaded(state, file, load, {:error, reason}) do
    Logger.warning("Loading ECB rates failed: #{file}: #{reason}")
    message = Fx.unavailable_message(reason)
    reply(load.waiters, {:error, message}, {:error, message})
    %{state | attempts: Map.put(state.attempts, file, {state.clock.(), message})}
  end

  defp reply(waiters, ensured, refreshed) do
    for {from, kind} <- waiters,
        do: GenServer.reply(from, if(kind == :ensure, do: ensured, else: refreshed))
  end

  defp merge(nil, range), do: range

  defp merge(cached, range),
    do:
      Date.range(
        Enum.min([cached.first, range.first], Date),
        Enum.max([cached.last, range.last], Date)
      )

  @doc """
  The file to load for `date`, or nil when the cache `range` has it or the ECB cannot have
  published since the last load (`fetched_at`; after a restart, the newest cached day).
  """
  @spec file_to_load(
          Date.Range.t() | nil,
          Date.t(),
          Date.t(),
          NaiveDateTime.t() | nil,
          NaiveDateTime.t()
        ) ::
          String.t() | nil
  def file_to_load(nil, date, today, _fetched_at, _now), do: file_reaching(date, today)

  def file_to_load(range, date, today, fetched_at, now) do
    cond do
      date in range ->
        nil

      Date.after?(date, range.last) ->
        last_load = fetched_at || NaiveDateTime.new!(range.last, @publish_at)
        if published_since?(last_load, now), do: file_reaching(range.last, today)

      true ->
        file_reaching(date, today)
    end
  end

  @doc "Whether the ECB published after `time` and by `now`: on weekdays at 16:00."
  @spec published_since?(NaiveDateTime.t(), NaiveDateTime.t()) :: boolean()
  def published_since?(time, now), do: not NaiveDateTime.after?(next_publication(time), now)

  defp next_publication(time) do
    publication = LocalTime.next_at(time, @publish_at)

    if Date.day_of_week(publication) in [6, 7],
      do: next_publication(publication),
      else: publication
  end

  @doc "The 90-day file when it reaches `day`, else the whole history."
  @spec file_reaching(Date.t(), Date.t()) :: String.t()
  def file_reaching(day, today) do
    if Date.before?(day, Date.add(today, -@recent_days)), do: Ecb.history(), else: Ecb.recent()
  end
end
