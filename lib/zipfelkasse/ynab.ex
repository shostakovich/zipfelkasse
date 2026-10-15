defmodule Zipfelkasse.Ynab do
  @moduledoc """
  Each person who connects YNAB gets their share of every expense as an outflow in an account of
  theirs there ("Geteilt" by convention), so its balance equals their balance here; bank payments
  and reimbursements are transfers inside YNAB. Everything is per person: a personal access
  token, plan, account, start date and category mapping. The app is the source of truth.

  The functions for the YNAB page answer `{:ok, message}` or `{:error, message}`, in German.
  """

  alias Zipfelkasse.{Balances, Categories, Dates, LocalTime}
  alias Zipfelkasse.Ynab.{Cache, Client, Connection, Connections, Error}
  alias Zipfelkasse.Ynab.{Scheduler, Selection, Transactions}

  @token_invalid "Der YNAB-Token ist ungültig oder abgelaufen. Bitte einen neuen Token eintragen."
  @not_ready "YNAB ist noch nicht fertig eingerichtet (Token, Plan, Konto und Startdatum)."
  @max_token 200

  @doc "The status message after YNAB refused the token."
  def token_invalid_message, do: @token_invalid

  @doc """
  YNAB's today: the earlier of the local and the UTC date, as YNAB rejects dates after today in
  UTC. `local_date` defaults to the local date of `now`.
  """
  def today(now \\ DateTime.utc_now(), local_date \\ nil) do
    local = local_date || LocalTime.date(now)
    utc = DateTime.to_date(now)
    if Date.before?(utc, local), do: utc, else: local
  end

  @doc "`message` without the token."
  def redact(message, nil), do: message
  def redact(message, token), do: String.replace(message, token, "•••")

  @doc """
  The selection of a connection (nil for none) whose plan and account were chosen at
  `connected_at`.
  """
  def selection(connection, connected_at, today)

  def selection(%Connection{start_date: %Date{}, account_id: account} = c, connected_at, today)
      when is_binary(account) do
    in_ynab =
      for t <- Transactions.list(c.participant_id),
          t.ynab_transaction_id || t.state == :pending,
          into: MapSet.new(),
          do: t.expense_id

    %Selection{today: today, start: c.start_date, connected_at: connected_at, in_ynab: in_ynab}
  end

  def selection(_connection, _connected_at, today), do: %Selection{today: today}

  @doc """
  A person's postings among `expenses` (with payer and shares), selected like the sync does, for
  the YNAB exports. Writes nothing. Option `:now`.
  """
  def postings(participant_id, expenses, opts \\ []) do
    connection = Connections.get(participant_id)
    today = today(Keyword.get_lazy(opts, :now, &DateTime.utc_now/0))

    connection
    |> selection(connection && connection.connected_at, today)
    |> Selection.postings(expenses, participant_id)
  end

  @doc "The plans the token reaches, cached for 10 minutes unless `refresh: true`."
  def plans(token, opts \\ []),
    do:
      Cache.fetch({:plans, Client.base_url(), token}, opts[:refresh], fn ->
        Client.plans(token)
      end)

  @doc "The category groups of a plan, cached like `plans/2`."
  def categories(token, plan_id, opts \\ []) do
    Cache.fetch({:categories, Client.base_url(), token, plan_id}, opts[:refresh], fn ->
      Client.categories(token, plan_id)
    end)
  end

  @doc "The accounts that can take expenses: on budget, open and not deleted."
  def usable_accounts(plan),
    do: Enum.filter(plan.accounts, &(&1.on_budget and not &1.closed and not &1.deleted))

  @doc """
  The category groups expenses can go to, as `%{name, categories: [%{id, name}]}`: without
  internal groups ("Inflow: Ready to Assign") and credit card payments, which YNAB rejects, and
  without hidden or deleted ones.
  """
  def usable_groups(groups) do
    for group <- groups,
        not (group.internal or group.hidden or group.deleted),
        group.name != "Credit Card Payments",
        categories =
          for(
            c <- group.categories,
            not (c.hidden or c.deleted or c.internal),
            do: %{id: c.id, name: c.name}
          ),
        categories != [],
        do: %{name: group.name, categories: categories}
  end

  defp known_categories(groups),
    do: MapSet.new(for group <- groups, category <- group.categories, do: category.id)

  defp category_names(groups),
    do:
      Map.new(for group <- groups, category <- group.categories, do: {category.id, category.name})

  @doc """
  Saves a personal access token after checking with YNAB that it works. If the new token cannot
  reach the chosen plan, plan and account are reset.
  """
  def save_token(participant_id, text) do
    token = String.trim(text)

    cond do
      token == "" ->
        {:error, "Bitte einen Token eingeben."}

      byte_size(token) > @max_token or String.contains?(token, [" ", "\t", "\r", "\n"]) ->
        {:error, "Das sieht nicht wie ein YNAB-Token aus."}

      true ->
        case plans(token, refresh: true) do
          {:ok, plans} -> put_token(participant_id, token, MapSet.new(plans, & &1.id))
          {:error, error} -> {:error, token_refused(error, token)}
        end
    end
  end

  defp token_refused(error, token) do
    if Error.kind(error) == :unauthorized,
      do: "YNAB kennt diesen Token nicht. Bitte prüfen und neu kopieren.",
      else: api_message(error, token)
  end

  defp put_token(participant_id, token, plan_ids) do
    {:ok, reset?} =
      Scheduler.change_connection(fn ->
        Connections.put_token(participant_id, token, plan_ids)
      end)

    if reset? do
      {:ok,
       "Token gespeichert. Der bisher gewählte Plan ist mit diesem Token nicht erreichbar – " <>
         "bitte Plan und Konto neu wählen."}
    else
      Scheduler.trigger()
      {:ok, "Token gespeichert."}
    end
  end

  @doc "Disconnects: forgets the token, keeps plan, account, mapping and what is in YNAB."
  def disconnect(participant_id) do
    {:ok, _reset?} =
      Scheduler.change_connection(fn -> Connections.put_token(participant_id, nil) end)

    {:ok, "YNAB-Verbindung getrennt. Die Buchungen in YNAB bleiben erhalten."}
  end

  @doc ~s(Chooses plan and account, given as "plan id|account id", and the start date.)
  def choose_target(participant_id, target, start) do
    with {:token, %Connection{token: token}} when is_binary(token) <-
           {:token, Connections.get(participant_id)},
         {:start, {:ok, start}} <- {:start, Dates.parse(start)},
         {:plans, {:ok, plans}} <- {:plans, plans(token)},
         [plan_id, account_id] <- String.split(target, "|", parts: 2),
         %{} = plan <- Enum.find(plans, &(&1.id == plan_id)),
         %{} = account <- Enum.find(usable_accounts(plan), &(&1.id == account_id)) do
      target = %{
        plan_id: plan_id,
        account_id: account_id,
        plan_name: plan.name,
        account_name: account.name,
        start: start
      }

      {:ok, _changed} =
        Scheduler.change_connection(fn -> Connections.put_target(participant_id, target) end)

      Scheduler.trigger()
      {:ok, "Gespeichert."}
    else
      {:token, _connection} ->
        {:error, "Bitte zuerst einen Token eingeben."}

      {:start, _error} ->
        {:error, "Bitte ein gültiges Startdatum angeben."}

      {:plans, {:error, error}} ->
        {:error, api_message(error, Connections.get(participant_id).token)}

      _no_account ->
        {:error, "Bitte Plan und Konto auswählen."}
    end
  end

  @doc """
  Maps app categories (ids, also as text) to YNAB category ids, `""` for none. A YNAB category no
  longer offered may stay mapped as it was.
  """
  def map_categories(participant_id, mapping) do
    with {:connection, %Connection{token: token, plan_id: plan_id}}
         when is_binary(token) and is_binary(plan_id) <-
           {:connection, Connections.get(participant_id)},
         {:categories, {:ok, groups}} <- {:categories, categories(token, plan_id)},
         mapping = ids(mapping),
         :ok <- check_mapping(participant_id, mapping, groups),
         {:ok, _changed} <-
           Connections.put_category_mapping(participant_id, mapping, category_names(groups)) do
      Scheduler.trigger()
      {:ok, "Kategorie-Zuordnung gespeichert."}
    else
      {:connection, _connection} ->
        {:error, "Bitte zuerst Token, Plan und Konto einrichten."}

      {:categories, {:error, error}} ->
        {:error, api_message(error, Connections.get(participant_id).token)}

      {:error, message} ->
        {:error, message}
    end
  end

  defp ids(mapping) do
    for {key, value} <- mapping, id = id(key), id != nil, into: %{}, do: {id, value}
  end

  defp id(key) when is_integer(key), do: key

  defp id(key) when is_binary(key) do
    case Integer.parse(key) do
      {id, ""} -> id
      _invalid -> nil
    end
  end

  defp check_mapping(participant_id, mapping, groups) do
    known = known_categories(usable_groups(groups))
    old = Connections.category_mapping(participant_id)

    if Enum.all?(mapping, fn {id, ynab_id} ->
         ynab_id == "" or MapSet.member?(known, ynab_id) or old[id] == ynab_id
       end),
       do: :ok,
       else: {:error, "Unbekannte YNAB-Kategorie. Bitte die Seite neu laden."}
  end

  @doc "Starts a full sync of the person in the background."
  def sync_now(participant_id) do
    if Connections.ready?(Connections.get(participant_id)) do
      Scheduler.sync_now(participant_id)
      {:ok, "Synchronisierung gestartet – Status unten aktualisiert sich nach dem Neuladen."}
    else
      {:error, @not_ready}
    end
  end

  @doc """
  Everything the YNAB page shows for a person: the connection and its status, the plans with
  their usable accounts (`%{name, accounts: [%{value, name, selected}]}`, value
  "plan id|account id"), a non-euro currency of the chosen plan, the categories with their
  mapping (`missing` if YNAB no longer offers the mapped one), the usable YNAB category groups,
  the synced count, failed expenses and the balance. `api_error` says why YNAB could not be asked.
  Options: `refresh: true` bypasses the cache, `:now`.
  """
  def overview(participant_id, opts \\ []) do
    connection = Connections.get(participant_id) || %Connection{participant_id: participant_id}
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    token_invalid? = not is_nil(connection.token) and connection.token_invalid
    remote = remote(connection, token_invalid?, opts[:refresh])
    has_target? = not is_nil(connection.account_id)
    {synced, problems} = Transactions.summary(participant_id)

    %{
      connection: connection,
      token_set: not is_nil(connection.token),
      token_invalid: token_invalid?,
      api_error: remote.api_error,
      plans: remote.plans,
      currency: remote.currency,
      has_target: has_target?,
      start_date: connection.start_date || today(now),
      categories: if(has_target?, do: category_rows(participant_id, remote.groups), else: []),
      groups: remote.groups,
      ready: Connections.ready?(connection),
      retry_at:
        if(connection.retry_at && DateTime.after?(connection.retry_at, now),
          do: connection.retry_at
        ),
      synced: synced,
      problems: problems,
      balance: Balances.balance(participant_id)
    }
  end

  defp remote(%Connection{token: token} = connection, false, refresh) when is_binary(token) do
    case plans(token, refresh: refresh) do
      {:ok, plans} ->
        {plans, currency} = plan_options(plans, connection)

        case groups(token, connection.plan_id, refresh) do
          {:ok, groups} ->
            %{plans: plans, currency: currency, groups: groups, api_error: nil}

          {:error, error} ->
            %{plans: plans, currency: currency, groups: [], api_error: api_message(error, token)}
        end

      {:error, error} ->
        %{plans: [], currency: nil, groups: [], api_error: api_message(error, token)}
    end
  end

  defp remote(_connection, _token_invalid?, _refresh),
    do: %{plans: [], currency: nil, groups: [], api_error: nil}

  defp groups(_token, nil, _refresh), do: {:ok, []}

  defp groups(token, plan_id, refresh) do
    with {:ok, groups} <- categories(token, plan_id, refresh: refresh),
         do: {:ok, usable_groups(groups)}
  end

  defp plan_options(plans, connection) do
    Enum.flat_map_reduce(plans, nil, fn plan, currency ->
      accounts =
        for account <- usable_accounts(plan) do
          selected = plan.id == connection.plan_id and account.id == connection.account_id
          %{value: plan.id <> "|" <> account.id, name: account.name, selected: selected}
        end

      currency =
        if Enum.any?(accounts, & &1.selected) and plan.currency != "EUR",
          do: plan.currency,
          else: currency

      if accounts == [],
        do: {[], currency},
        else: {[%{name: plan.name, accounts: accounts}], currency}
    end)
  end

  defp category_rows(participant_id, groups) do
    mapping = Connections.category_mapping(participant_id)
    known = known_categories(groups)

    for category <- Categories.list_categories(:all),
        is_nil(category.archived_at) or Map.has_key?(mapping, category.id) do
      selected = Map.get(mapping, category.id)

      %{
        id: category.id,
        name: category.name,
        archived: not is_nil(category.archived_at),
        selected: selected,
        missing: not is_nil(selected) and groups != [] and not MapSet.member?(known, selected)
      }
    end
  end

  defp api_message(error, token) do
    if Error.kind(error) == :unauthorized,
      do: @token_invalid,
      else: "YNAB ist gerade nicht erreichbar: " <> redact(Exception.message(error), token)
  end
end
