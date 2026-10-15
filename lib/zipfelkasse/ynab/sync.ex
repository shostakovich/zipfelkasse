defmodule Zipfelkasse.Ynab.Sync do
  @moduledoc """
  Syncs a person's shares to YNAB and keeps the state of the connection: after an invalid token
  it waits for a new one, after a rate limit it backs off from 5 minutes up to an hour (at least
  as long as YNAB asks), and after an unclear error it tries again in 5 minutes. Callers make
  sure only one sync runs at a time (see `Zipfelkasse.Ynab.Scheduler`).
  """

  require Logger

  alias Zipfelkasse.{Expenses, LocalTime, Schema, Ynab}
  alias Zipfelkasse.Ynab.{Connection, Connections, Error, Result, Run, Want}

  @retry_delay 5 * 60
  @max_backoff 60 * 60
  @full_interval :timer.hours(1)

  defmodule Outcome do
    @moduledoc "What a sync of a person did, or why it was skipped."
    defstruct result: %Zipfelkasse.Ynab.Result{},
              status: %Zipfelkasse.Ynab.Connection{},
              error: nil,
              message: nil,
              skipped: nil

    @type t :: %__MODULE__{}
  end

  @doc "The interval of the full sync, which also retries what failed."
  def full_interval, do: @full_interval

  @doc """
  Syncs everybody connected; returns the milliseconds until the next run: an hour, sooner when a
  run asks for another one (after `:debounce`) or a pause ends. Options: `:debounce`, `:now`.
  """
  def sync_all(full?, opts \\ []) do
    connections =
      try do
        {:ok, Connections.list_connected()}
      rescue
        error ->
          Logger.error("YNAB: reading the connections failed: " <> Exception.message(error))
          :error
      end

    case connections do
      {:ok, connections} ->
        Enum.reduce(connections, @full_interval, &next_run(&1, &2, full?, opts))

      :error ->
        :timer.seconds(@retry_delay)
    end
  end

  defp next_run(connection, next_run, full?, opts) do
    if Connections.ready?(connection) do
      outcome = sync_person(connection.participant_id, full?, opts)

      next_run =
        if outcome.result.again,
          do: min(next_run, Keyword.get(opts, :debounce, :timer.seconds(5))),
          else: next_run

      until_retry(
        next_run,
        outcome.status.retry_at,
        Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
      )
    else
      next_run
    end
  end

  defp until_retry(next_run, nil, _now), do: next_run

  defp until_retry(next_run, retry_at, now) do
    wait = DateTime.diff(retry_at, now, :millisecond)
    if wait > 0, do: min(next_run, wait + 1000), else: next_run
  end

  @doc """
  Syncs a person: a full sync also retries failed transactions and deletions. Options: `:now`,
  `:manual` (logged as such).
  """
  @spec sync_person(integer(), boolean(), keyword()) :: Outcome.t()
  def sync_person(participant_id, full?, opts \\ []) do
    now = opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> Schema.usec()

    outcome =
      try do
        sync_connected(participant_id, full?, now)
      rescue
        error -> %Outcome{error: error, message: Exception.message(error)}
      end

    log(participant_id, outcome, opts[:manual] == true)
    outcome
  end

  defp sync_connected(participant_id, full?, now) do
    connection = Connections.get(participant_id)

    cond do
      not Connections.ready?(connection) ->
        %Outcome{skipped: :not_ready}

      connection.token_invalid ->
        %Outcome{status: connection, skipped: :token_invalid}

      connection.retry_at && DateTime.before?(now, connection.retry_at) ->
        %Outcome{status: connection, skipped: :backed_off}

      true ->
        run(connection, full?, now)
    end
  end

  defp run(connection, full?, now) do
    {result, error} =
      try do
        connected_at =
          connection.connected_at ||
            Connections.ensure_connected_at(connection.participant_id, now)

        case Run.call(Run.new(connection, now), wants(connection, connected_at, now), full?) do
          {:ok, run} -> {run.result, nil}
          {:error, error, run} -> {run.result, error}
        end
      rescue
        error -> {%Result{}, error}
      end

    message = error && Ynab.redact(Exception.message(error), connection.token)
    status = status_after(connection, now, result, error, message)
    Connections.put_status(connection.participant_id, status)
    %Outcome{result: result, status: status, error: error, message: message}
  end

  defp status_after(status, now, result, nil, _message) do
    %{
      status
      | last_run_at: now,
        last_synced_at: now,
        summary: Result.summary(result),
        error: nil,
        backoff_seconds: 0,
        retry_at: nil
    }
  end

  defp status_after(status, now, _result, error, message) do
    status = %{status | last_run_at: now}

    case Error.kind(error) do
      :unauthorized ->
        %{status | token_invalid: true, error: Ynab.token_invalid_message()}

      :rate_limited ->
        backoff = (status.backoff_seconds * 2) |> max(@retry_delay) |> min(@max_backoff)
        retry_at = DateTime.add(now, max(backoff, error.retry_after), :second)
        at = retry_at |> LocalTime.from_utc() |> Calendar.strftime("%H:%M")

        %{
          status
          | backoff_seconds: backoff,
            retry_at: retry_at,
            error: "Das YNAB-Anfragelimit ist erreicht. Nächster Versuch um #{at} Uhr."
        }

      :not_found ->
        %{
          status
          | error:
              "Plan oder Konto gibt es in YNAB nicht (mehr). Bitte Plan und Konto neu wählen."
        }

      :unclear ->
        %{status | retry_at: DateTime.add(now, @retry_delay, :second), error: message}

      _other ->
        %{status | error: message}
    end
  end

  defp wants(%Connection{} = connection, connected_at, now) do
    participant_id = connection.participant_id
    selection = Ynab.selection(connection, connected_at, Ynab.today(now))
    mapping = Connections.category_mapping(participant_id)

    selection
    |> Ynab.Selection.postings(
      Expenses.list_expenses(participant_id: participant_id),
      participant_id
    )
    |> Map.new(fn posting ->
      {posting.expense_id, Want.new(posting, posting.category_id && mapping[posting.category_id])}
    end)
  end

  # A skipped sync recurs on every run and the YNAB page shows why, so it is not logged.
  defp log(_participant_id, %Outcome{skipped: skipped}, _manual?) when not is_nil(skipped),
    do: :ok

  defp log(participant_id, %Outcome{} = outcome, manual?) do
    how = if manual?, do: " (now)", else: ""
    r = outcome.result

    cond do
      outcome.message ->
        Logger.warning("YNAB sync#{how} failed for person #{participant_id}: #{outcome.message}")

      manual? or Result.changes(r) > 0 ->
        Logger.info(
          "YNAB synced#{how} for person #{participant_id}: #{r.created} created, " <>
            "#{r.updated} updated, #{r.deleted} deleted, #{r.failed} failed"
        )

      true ->
        :ok
    end
  end
end
