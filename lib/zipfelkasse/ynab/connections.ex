defmodule Zipfelkasse.Ynab.Connections do
  @moduledoc """
  The stored YNAB connections: token, target (plan, account, start date), the category mapping
  and the state of the last sync. Changes of the connection are logged with the person as actor.
  """

  import Ecto.Query

  alias Zipfelkasse.{Activities, Categories, Dates, Repo, Schema}
  alias Zipfelkasse.Participants.Participant
  alias Zipfelkasse.Ynab.{CategoryMapping, Connection, Transaction}

  @status_fields [
    :last_run_at,
    :last_synced_at,
    :summary,
    :error,
    :token_invalid,
    :retry_at,
    :backoff_seconds
  ]

  @doc "The connection of a person, or nil."
  def get(participant_id), do: Repo.get(Connection, participant_id)

  @doc "Whether token, plan, account and start date are there, so it can sync."
  def ready?(%Connection{} = c),
    do:
      not is_nil(c.token) and not is_nil(c.plan_id) and not is_nil(c.account_id) and
        not is_nil(c.start_date)

  def ready?(nil), do: false

  @doc "The connections with a token of active people, by participant id."
  def list_connected do
    Repo.all(
      from c in Connection,
        join: p in Participant,
        on: p.id == c.participant_id,
        where: not is_nil(c.token) and is_nil(p.archived_at),
        order_by: c.participant_id
    )
  end

  @doc """
  Saves a token, or nil to disconnect. Plan, account, mapping and sync state stay, so that
  reconnecting creates no duplicates. If `plan_ids` (the plans the new token reaches) lacks the
  chosen plan, plan and account are reset; returns whether they were.
  """
  def put_token(participant_id, token, plan_ids \\ nil, now \\ DateTime.utc_now()) do
    now = Schema.usec(now)

    Repo.transact(fn ->
      old = get(participant_id)

      Repo.insert!(%Connection{participant_id: participant_id, token: token},
        on_conflict: [
          set: [
            token: token,
            token_invalid: false,
            error: nil,
            retry_at: nil,
            backoff_seconds: 0,
            updated_at: now
          ]
        ],
        conflict_target: :participant_id
      )

      reset? = target_lost?(old, token, plan_ids)
      if reset?, do: set_target(participant_id, nil, nil, old.start_date, now)

      with {:ok, _activity} <-
             Activities.log_settings(participant_id, token_text(old, token, reset?)),
           do: {:ok, reset?}
    end)
  end

  defp target_lost?(%Connection{plan_id: plan_id}, token, plan_ids)
       when is_binary(token) and is_binary(plan_id) and not is_nil(plan_ids),
       do: plan_id not in plan_ids

  defp target_lost?(_old, _token, _plan_ids), do: false

  defp token_text(_old, nil, _reset?), do: "YNAB-Verbindung getrennt"
  defp token_text(_old, _token, true), do: "YNAB-Token ersetzt (Plan und Konto zurückgesetzt)"

  defp token_text(%Connection{token: old}, _token, false) when is_binary(old),
    do: "YNAB-Token ersetzt"

  defp token_text(_old, _token, false), do: "YNAB verbunden (Token gesetzt)"

  @doc """
  Chooses plan, account (with their names for the log) and start date. Another plan or account
  is a new setup: transactions are looked up there again and `connected_at` starts anew.
  """
  def put_target(participant_id, target, now \\ DateTime.utc_now()) do
    now = Schema.usec(now)

    Repo.transact(fn ->
      old = set_target(participant_id, target.plan_id, target.account_id, target.start, now)

      log_target(participant_id, target_text(old, target))
    end)
  end

  defp target_text(old, target) do
    cond do
      {target.plan_id, target.account_id} != {old.plan_id, old.account_id} ->
        "YNAB: Konto „#{target.account_name || target.account_id}“ im Plan " <>
          "„#{target.plan_name || target.plan_id}“ gewählt, Startdatum #{Dates.format(target.start)}"

      target.start != old.start_date ->
        "YNAB: Startdatum #{format(old.start_date)} → #{Dates.format(target.start)}"

      true ->
        nil
    end
  end

  defp log_target(_participant_id, nil), do: {:ok, :unchanged}

  defp log_target(participant_id, text) do
    with {:ok, _activity} <- Activities.log_settings(participant_id, text), do: {:ok, :changed}
  end

  defp format(nil), do: "–"
  defp format(date), do: Dates.format(date)

  defp set_target(participant_id, plan_id, account_id, start, now) do
    old = Repo.get!(Connection, participant_id)
    moved? = {plan_id, account_id} != {old.plan_id, old.account_id}

    if moved? do
      Repo.update_all(where(Transaction, participant_id: ^participant_id),
        set: [
          ynab_transaction_id: nil,
          state: :retarget,
          fingerprint: nil,
          synced_at: nil,
          last_error: nil
        ]
      )
    end

    old
    |> Ecto.Changeset.change(
      plan_id: plan_id,
      account_id: account_id,
      start_date: start,
      connected_at: if(moved?, do: now, else: old.connected_at),
      updated_at: now
    )
    |> Repo.update!(force: true)

    old
  end

  @doc "Since when plan and account are chosen; set to `now` for an older connection without it."
  def ensure_connected_at(participant_id, now \\ DateTime.utc_now()) do
    {:ok, connected_at} =
      Repo.transact(fn ->
        Repo.update_all(
          where(Connection, [c], c.participant_id == ^participant_id and is_nil(c.connected_at)),
          set: [connected_at: Schema.usec(now)]
        )

        {:ok, Repo.get!(Connection, participant_id).connected_at}
      end)

    connected_at
  end

  @doc "Stores the state of a sync: the status fields of `status`, a connection."
  def put_status(participant_id, %Connection{} = status) do
    {1, _} =
      Repo.update_all(where(Connection, participant_id: ^participant_id),
        set: status |> Map.take(@status_fields) |> Enum.to_list()
      )

    :ok
  end

  @doc "The YNAB category of each app category the person mapped, by category id."
  def category_mapping(participant_id) do
    Repo.all(
      from m in CategoryMapping,
        where: m.participant_id == ^participant_id,
        select: {m.category_id, m.ynab_category_id}
    )
    |> Map.new()
  end

  @doc """
  Replaces the mapping (category id to YNAB category id, `""` for none); `ynab_names` names the
  YNAB categories for the log.
  """
  def put_category_mapping(participant_id, mapping, ynab_names) do
    Repo.transact(fn ->
      old = category_mapping(participant_id)
      categories = Categories.list_categories(:all)
      known = MapSet.new(categories, & &1.id)
      mapped = Map.reject(mapping, fn {_id, ynab_id} -> ynab_id == "" end)

      if Enum.all?(Map.keys(mapped), &MapSet.member?(known, &1)) do
        replace_mapping(participant_id, mapped)
        log_mapping(participant_id, mapping_changes(categories, old, mapped, ynab_names))
      else
        {:error, "Unbekannte Kategorie."}
      end
    end)
  end

  defp replace_mapping(participant_id, mapped) do
    Repo.delete_all(where(CategoryMapping, participant_id: ^participant_id))

    Repo.insert_all(
      CategoryMapping,
      for {category_id, ynab_id} <- mapped do
        %{participant_id: participant_id, category_id: category_id, ynab_category_id: ynab_id}
      end
    )
  end

  defp log_mapping(_participant_id, ""), do: {:ok, :unchanged}

  defp log_mapping(participant_id, text) do
    with {:ok, _activity} <-
           Activities.log_settings(
             participant_id,
             "YNAB: Kategorie-Zuordnung geändert (#{text})"
           ),
         do: {:ok, :changed}
  end

  defp mapping_changes(categories, old, new, ynab_names) do
    name = fn
      "" -> "unkategorisiert"
      id -> Map.get(ynab_names, id) || "(nicht mehr vorhanden)"
    end

    categories
    |> Enum.flat_map(fn category ->
      before = Map.get(old, category.id, "")
      now = Map.get(new, category.id, "")

      cond do
        before == now -> []
        before == "" -> ["#{category.name} → #{name.(now)}"]
        true -> ["#{category.name} → #{name.(now)} (vorher #{name.(before)})"]
      end
    end)
    |> Enum.join(", ")
  end
end
