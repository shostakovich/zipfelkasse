defmodule Zipfelkasse.Ynab.Run do
  @moduledoc """
  One sync run of a person against YNAB: resolves transactions of unclear outcome, then creates,
  updates and deletes in chunks of 100. A rejected batch is retried transaction by transaction
  (at most 20); after 3 failures in a row without a success, the rest waits for the full sync.
  At most 40 deletions per run. Anything but a rejected transaction stops the run.
  """

  alias Zipfelkasse.Ynab
  alias Zipfelkasse.Ynab.{Client, Error, Plan, Posting, Result, Transaction, Transactions, Want}

  @chunk 100
  @max_deletes 40
  @max_single 20
  @systemic_failures 3

  @derive {Inspect, except: [:token]}
  @enforce_keys [:participant_id, :token, :plan_id, :account_id, :now]
  defstruct [
    :participant_id,
    :token,
    :plan_id,
    :account_id,
    :now,
    confirmed: false,
    result: %Result{}
  ]

  @type t :: %__MODULE__{}

  @doc "A run with the token and target of a ready connection."
  def new(connection, now) do
    %__MODULE__{
      participant_id: connection.participant_id,
      token: connection.token,
      plan_id: connection.plan_id,
      account_id: connection.account_id,
      now: now
    }
  end

  @doc """
  Brings YNAB to `wants` (by expense id). Returns the run with its result, and the error that
  stopped it, if any.
  """
  @spec call(t(), %{integer() => Want.t()}, boolean()) ::
          {:ok, t()} | {:error, Exception.t(), t()}
  def call(%__MODULE__{} = run, wants, full?) do
    rows = Map.new(Transactions.list(run.participant_id), &{&1.expense_id, &1})

    with {:ok, run, rows} <- resolve_unclear(run, rows, wants) do
      plan = Plan.build(wants, rows, full?)
      Transactions.delete(run.participant_id, plan.forget)

      with {:ok, run} <- create(run, plan.creates),
           {:ok, run} <- update(run, plan.updates),
           do: remove(run, plan.deletes)
    end
  end

  # One request for the whole account: the date of the expense may have moved since.
  defp resolve_unclear(run, rows, wants) do
    unclear =
      rows
      |> Map.values()
      |> Enum.filter(
        &(&1.state == :pending or (&1.state == :retarget and is_map_key(wants, &1.expense_id)))
      )

    if unclear == [], do: {:ok, run, rows}, else: look_up(run, rows, unclear)
  end

  defp look_up(run, rows, unclear) do
    case Client.account_transactions(run.token, run.plan_id, run.account_id) do
      {:ok, transactions} ->
        found = by_marker(Enum.reject(transactions, & &1.deleted))

        resolved =
          Enum.map(unclear, &row(run, &1.expense_id, ynab_transaction_id: found[&1.expense_id]))

        Transactions.put(resolved)
        {:ok, run, Map.merge(rows, Map.new(resolved, &{&1.expense_id, &1}))}

      {:error, error} ->
        {:error, error, run}
    end
  end

  defp by_marker(transactions) do
    for %{memo: memo, id: id} <- transactions,
        expense_id = Posting.marker_id(memo || ""),
        expense_id != nil,
        into: %{},
        do: {expense_id, id}
  end

  defp create(run, wants) do
    wants
    |> Enum.chunk_every(@chunk)
    |> reduce_ok(run, fn chunk, run ->
      mark_pending(run, chunk)

      case Client.create_transactions(
             run.token,
             run.plan_id,
             Enum.map(chunk, &Want.new_transaction(&1, run.account_id))
           ) do
        {:ok, created} -> {:ok, apply_created(run, chunk, created)}
        {:error, error} -> created_failed(run, chunk, error)
      end
    end)
  end

  defp created_failed(run, chunk, error) do
    case Error.kind(error) do
      :unclear ->
        {:error, error, run}

      :rejected ->
        create_each(run, chunk)

      _aborts ->
        unmark_pending(run, chunk)
        {:error, error, run}
    end
  end

  defp mark_pending(run, wants),
    do: Transactions.put(Enum.map(wants, &row(run, Want.expense_id(&1), state: :pending)))

  defp unmark_pending(run, wants),
    do: Transactions.put(Enum.map(wants, &row(run, Want.expense_id(&1))))

  defp apply_created(run, wants, created) do
    ids = by_marker(created)

    {rows, run} =
      Enum.map_reduce(wants, run, fn want, run ->
        case ids[Want.expense_id(want)] do
          nil ->
            row =
              row(run, Want.expense_id(want),
                state: :pending,
                last_error: "YNAB hat das Anlegen nicht bestätigt."
              )

            {row, count(run, failed: 1, again: true)}

          id ->
            {synced(run, want, id), count(run, created: 1)}
        end
      end)

    Transactions.put(rows)
    run
  end

  defp create_each(run, wants), do: create_each(run, wants, 0, false)

  defp create_each(run, [], _index, _succeeded?), do: {:ok, run}

  defp create_each(run, wants, @max_single, _succeeded?) do
    unmark_pending(run, wants)
    {:ok, count(run, again: true)}
  end

  defp create_each(run, [want | rest], index, succeeded?) do
    case Client.create_transactions(run.token, run.plan_id, [
           Want.new_transaction(want, run.account_id)
         ]) do
      {:ok, created} ->
        run |> apply_created([want], created) |> create_each(rest, index + 1, true)

      {:error, error} ->
        case Error.kind(error) do
          :unclear ->
            unmark_pending(run, rest)
            {:error, error, run}

          :rejected ->
            run = count(run, failed: 1)
            Transactions.put([failed_row(run, want, nil, error)])
            continue_after_failure(run, rest, index, succeeded?, error, &create_each/4)

          _aborts ->
            unmark_pending(run, [want | rest])
            {:error, error, run}
        end
    end
  end

  # Everything failing the same way (e.g. a closed account): the rest waits for the full sync.
  defp continue_after_failure(run, rest, index, succeeded?, error, next) do
    if not succeeded? and index + 1 >= @systemic_failures do
      {:ok, fail_all(run, Enum.map(rest, &failed_pair/1), error)}
    else
      next.(run, rest, index + 1, succeeded?)
    end
  end

  defp failed_pair({%Want{} = want, transaction_id}), do: {want, transaction_id}
  defp failed_pair(%Want{} = want), do: {want, nil}

  defp update(run, updates) do
    updates
    |> Enum.chunk_every(@chunk)
    |> reduce_ok(run, fn chunk, run ->
      patches = Enum.map(chunk, fn {want, id} -> Want.patch_transaction(want, id) end)

      case Client.update_transactions(run.token, run.plan_id, patches) do
        {:ok, updated} ->
          {:ok, apply_updated(run, chunk, updated)}

        {:error, error} ->
          updates_failed(run, chunk, error)
      end
    end)
  end

  defp updates_failed(run, chunk, error) do
    if Error.aborts_run?(error) and Error.kind(error) != :not_found,
      do: {:error, error, run},
      else: update_each(run, chunk, 0, false)
  end

  defp apply_updated(run, updates, updated) do
    by_id = Map.new(updated, &{&1.id, &1})

    {rows, run} =
      Enum.map_reduce(updates, run, fn {want, id}, run ->
        case by_id[id] do
          nil ->
            row = failed_row(run, want, id, "YNAB hat die Änderung nicht bestätigt.")
            {row, count(run, failed: 1)}

          # Deleted by hand in YNAB: the app is authoritative and creates it again.
          %{deleted: true} ->
            {row(run, Want.expense_id(want)), count(run, again: true)}

          _transaction ->
            {synced(run, want, id), count(run, updated: 1)}
        end
      end)

    Transactions.put(rows)
    run
  end

  defp update_each(run, [], _index, _succeeded?), do: {:ok, run}
  defp update_each(run, _updates, @max_single, _succeeded?), do: {:ok, count(run, again: true)}

  defp update_each(run, [{want, id} = update | rest], index, succeeded?) do
    case Client.update_transactions(run.token, run.plan_id, [Want.patch_transaction(want, id)]) do
      {:ok, updated} ->
        run |> apply_updated([update], updated) |> update_each(rest, index + 1, true)

      {:error, error} ->
        update_failed(run, update, rest, index, succeeded?, error)
    end
  end

  defp update_failed(run, {want, id}, rest, index, succeeded?, error) do
    case Error.kind(error) do
      :not_found ->
        with {:ok, run} <- confirm_target(run) do
          Transactions.put([row(run, Want.expense_id(want))])
          run |> count(again: true) |> update_each(rest, index + 1, true)
        end

      :rejected ->
        run = count(run, failed: 1)
        Transactions.put([failed_row(run, want, id, error)])
        continue_after_failure(run, rest, index, succeeded?, error, &update_each/4)

      _aborts ->
        {:error, error, run}
    end
  end

  defp remove(run, rows) do
    rows
    |> Enum.with_index()
    |> reduce_ok(run, fn
      {_row, index}, run when index >= @max_deletes ->
        {:halt, count(run, again: true)}

      {row, _index}, run ->
        result = Client.delete_transaction(run.token, run.plan_id, row.ynab_transaction_id)
        removed(run, row, result)
    end)
  end

  defp removed(run, row, :ok) do
    Transactions.delete(run.participant_id, [row.expense_id])
    {:ok, count(run, deleted: 1)}
  end

  defp removed(run, row, {:error, error}) do
    case Error.kind(error) do
      :not_found ->
        with {:ok, run} <- confirm_target(run), do: removed(run, row, :ok)

      :rejected ->
        Transactions.put([
          %{
            row
            | state: :delete_failed,
              last_error: Ynab.redact(Exception.message(error), run.token)
          }
        ])

        {:ok, count(run, failed: 1)}

      _aborts ->
        {:error, error, run}
    end
  end

  # YNAB answers 404 for everything when the token cannot see the plan, so the account is checked first.
  defp confirm_target(%__MODULE__{confirmed: true} = run), do: {:ok, run}

  defp confirm_target(run) do
    case Client.account(run.token, run.plan_id, run.account_id) do
      {:ok, %{deleted: true}} -> {:error, Error.api(404, "Konto gelöscht"), run}
      {:ok, _account} -> {:ok, %{run | confirmed: true}}
      {:error, error} -> {:error, error, run}
    end
  end

  defp fail_all(run, pairs, error) do
    Transactions.put(Enum.map(pairs, fn {want, id} -> failed_row(run, want, id, error) end))
    count(run, failed: length(pairs))
  end

  defp failed_row(run, want, transaction_id, error) do
    message = if is_binary(error), do: error, else: Exception.message(error)

    row(run, Want.expense_id(want),
      ynab_transaction_id: transaction_id,
      state: :failed,
      fingerprint: want.fingerprint,
      last_error: Ynab.redact(message, run.token)
    )
  end

  defp synced(run, want, id) do
    row(run, Want.expense_id(want),
      ynab_transaction_id: id,
      state: :synced,
      fingerprint: want.fingerprint,
      synced_at: run.now
    )
  end

  defp row(run, expense_id, fields \\ []),
    do: struct(%Transaction{expense_id: expense_id, participant_id: run.participant_id}, fields)

  defp count(%__MODULE__{result: result} = run, changes) do
    result =
      Enum.reduce(changes, result, fn
        {:again, again}, result -> %{result | again: result.again or again}
        {key, n}, result -> Map.update!(result, key, &(&1 + n))
      end)

    %{run | result: result}
  end

  defp reduce_ok(items, run, fun) do
    Enum.reduce_while(items, {:ok, run}, fn item, {:ok, run} ->
      case fun.(item, run) do
        {:ok, run} -> {:cont, {:ok, run}}
        {:halt, run} -> {:halt, {:ok, run}}
        {:error, _error, _run} = error -> {:halt, error}
      end
    end)
  end
end
