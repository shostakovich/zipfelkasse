defmodule Zipfelkasse.FakeYnab do
  @moduledoc """
  YNAB's API in memory, served by Bandit on a free port and pointed at by
  `Zipfelkasse.Ynab.Client`. `token/0` reaches the plan `plan/0`; `other_token/0` is valid but
  another YNAB user's, so everything below that plan is a 404 for it.

  Failure injection: `fail/2` answers the next requests with the given statuses (`{429, seconds}`
  with that Retry-After, a plain 429 with 60 seconds), `lose_post/1` executes the next POST but
  loses its answer (500), `bare_list/2` answers the transaction list without its data, and
  `hold/1` makes every request but the plan list wait for `release/1`.
  """

  @behaviour Plug

  import Plug.Conn

  @token "secret-token-123"
  @other_token "other-user-token"
  @plan "plan-1"
  @account "acc-geteilt"

  @accounts [
    %{
      id: @account,
      name: "Geteilt",
      type: "cash",
      on_budget: true,
      closed: false,
      deleted: false
    },
    %{
      id: "acc-giro",
      name: "Girokonto",
      type: "checking",
      on_budget: true,
      closed: false,
      deleted: false
    },
    %{
      id: "acc-depot",
      name: "Depot",
      type: "otherAsset",
      on_budget: false,
      closed: false,
      deleted: false
    },
    %{
      id: "acc-alt",
      name: "Altes Konto",
      type: "checking",
      on_budget: true,
      closed: true,
      deleted: false
    }
  ]

  def token, do: @token
  def other_token, do: @other_token
  def plan, do: @plan
  def account, do: @account

  @doc "Starts the fake for the running test."
  def start do
    {:ok, agent} =
      ExUnit.Callbacks.start_supervised(
        {Agent,
         fn ->
           %{
             txns: %{},
             next_id: 0,
             requests: [],
             fail: [],
             lost_post: false,
             bare_list: false,
             hold: false,
             waiting: []
           }
         end},
        id: {__MODULE__, :state}
      )

    server =
      ExUnit.Callbacks.start_supervised!(
        {Bandit, plug: {__MODULE__, agent}, ip: :loopback, port: 0, startup_log: false},
        id: {__MODULE__, :server}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    previous = Application.get_env(:zipfelkasse, Zipfelkasse.Ynab.Client)

    Application.put_env(:zipfelkasse, Zipfelkasse.Ynab.Client,
      base_url: "http://127.0.0.1:#{port}/v1"
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:zipfelkasse, Zipfelkasse.Ynab.Client, previous)
    end)

    agent
  end

  def fail(fake, statuses) do
    statuses = Enum.map(List.wrap(statuses), &if(&1 == 429, do: {429, 60}, else: &1))
    update(fake, &%{&1 | fail: &1.fail ++ statuses})
  end

  def lose_post(fake), do: update(fake, &%{&1 | lost_post: true})
  def bare_list(fake, bare?), do: update(fake, &%{&1 | bare_list: bare?})
  def hold(fake), do: update(fake, &%{&1 | hold: true})

  def release(fake) do
    waiting = Agent.get_and_update(fake, &{&1.waiting, %{&1 | hold: false, waiting: []}})
    Enum.each(waiting, &send(&1, :release))
  end

  @doc ~s(The requests since the last call, as "METHOD /path".)
  def take_requests(fake),
    do: Agent.get_and_update(fake, &{Enum.reverse(&1.requests), %{&1 | requests: []}})

  def request_count(fake), do: Agent.get(fake, &length(&1.requests))

  @doc "All transactions, deleted ones too, by id number."
  def all(fake), do: fake |> Agent.get(& &1.txns) |> Map.values() |> Enum.sort_by(&id_number/1)

  @doc "The transactions that are not deleted."
  def live(fake), do: fake |> all() |> Enum.reject(& &1.deleted)

  @doc "Changes a transaction as if by hand in YNAB."
  def change(fake, id, fun), do: update(fake, fn state -> update_in(state.txns[id], fun) end)

  @doc "Removes a transaction completely, so YNAB no longer knows it."
  def forget(fake, id),
    do: update(fake, fn state -> %{state | txns: Map.delete(state.txns, id)} end)

  defp update(fake, fun), do: Agent.update(fake, fun)

  defp id_number(%{id: "t" <> number}), do: String.to_integer(number)

  @impl true
  def init(agent), do: agent

  @impl true
  def call(conn, agent) do
    caller = self()

    {failure, hold?} =
      Agent.get_and_update(agent, fn state ->
        {failure, rest} = List.pop_at(state.fail, 0, 0)
        hold? = state.hold and conn.request_path != "/v1/plans"
        waiting = if hold?, do: [caller | state.waiting], else: state.waiting
        requests = ["#{conn.method} #{conn.request_path}" | state.requests]
        {{failure, hold?}, %{state | fail: rest, waiting: waiting, requests: requests}}
      end)

    if hold? do
      receive do
        :release -> :ok
      after
        30_000 -> :ok
      end
    end

    conn = fetch_query_params(conn)

    case {get_req_header(conn, "authorization"), failure} do
      {auth, _failure} when auth not in [["Bearer " <> @token], ["Bearer " <> @other_token]] ->
        error(conn, 401, "unauthorized", "Unauthorized")

      {_auth, {429, seconds}} ->
        rate_limited(conn, seconds)

      {_auth, status} when status != 0 ->
        error(conn, status, "error", "Error #{status} with #{@token}")

      {["Bearer " <> @other_token], 0} ->
        other_user(conn)

      {_auth, 0} ->
        route(conn, agent)
    end
  end

  defp rate_limited(conn, seconds) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(seconds))
    |> error(429, "too_many_requests", "Too many requests")
  end

  defp route(conn, agent) do
    case {conn.method, conn.path_info} do
      {"GET", ["v1", "plans"]} ->
        plans(conn)

      {"GET", ["v1", "plans", plan, "categories"]} ->
        categories(conn, plan)

      {"POST", ["v1", "plans", @plan, "transactions"]} ->
        create(conn, agent)

      {"PATCH", ["v1", "plans", @plan, "transactions"]} ->
        patch(conn, agent)

      {"DELETE", ["v1", "plans", @plan, "transactions", id]} ->
        delete(conn, agent, id)

      {"GET", ["v1", "plans", plan, "accounts", account]} ->
        account(conn, plan, account)

      {"GET", ["v1", "plans", @plan, "accounts", account, "transactions"]} ->
        list(conn, agent, account)

      _other ->
        not_found(conn)
    end
  end

  defp plans(conn) do
    if conn.query_params["include_accounts"] == "true",
      do:
        data(conn, 200, %{
          plans: [
            %{
              id: @plan,
              name: "Haushalt",
              currency_format: %{iso_code: "EUR"},
              accounts: @accounts
            }
          ]
        }),
      else: error(conn, 400, "bad_request", "include_accounts missing")
  end

  defp other_user(%{method: "GET", request_path: "/v1/plans"} = conn) do
    account = %{
      id: "acc-2",
      name: "Geteilt",
      type: "cash",
      on_budget: true,
      closed: false,
      deleted: false
    }

    data(conn, 200, %{plans: [%{id: "plan-2", name: "Anderer Haushalt", accounts: [account]}]})
  end

  defp other_user(conn), do: not_found(conn)

  defp account(conn, @plan, id) do
    case Enum.find(@accounts, &(&1.id == id)) do
      nil -> not_found(conn)
      account -> data(conn, 200, %{account: account})
    end
  end

  defp account(conn, _plan, _id), do: not_found(conn)

  defp categories(conn, @plan) do
    category = fn id, name, hidden -> %{id: id, name: name, hidden: hidden, deleted: false} end

    data(conn, 200, %{
      server_knowledge: 1,
      category_groups: [
        %{
          id: "g-int",
          name: "Internal Master Category",
          hidden: false,
          internal: true,
          deleted: false,
          categories: [category.("c-rta", "Inflow: Ready to Assign", false)]
        },
        %{
          id: "g-cc",
          name: "Credit Card Payments",
          hidden: false,
          internal: false,
          deleted: false,
          categories: [category.("c-visa", "Visa", false)]
        },
        %{
          id: "g-1",
          name: "Alltag",
          hidden: false,
          internal: false,
          deleted: false,
          categories: [
            category.("c-food", "Lebensmittel & Drogerie", false),
            category.("c-out", "Essen gehen", false),
            category.("c-old", "Versteckt", true)
          ]
        },
        %{
          id: "g-2",
          name: "Wohnen & <Freizeit>",
          hidden: false,
          internal: false,
          deleted: false,
          categories: [
            category.("c-rent", "Miete", false),
            category.("c-fun", ~s(Kino & "Konzerte"), false)
          ]
        }
      ]
    })
  end

  defp categories(conn, _plan), do: error(conn, 404, "not_found", "plan")

  defp create(conn, agent) do
    case body_transactions(conn) do
      {conn, [_ | _] = txns} ->
        cond do
          Enum.any?(txns, &Map.has_key?(&1, "import_id")) ->
            error(conn, 400, "bad_request", "import_id not expected")

          Enum.any?(txns, &String.contains?(&1["payee_name"] || "", "REJECT")) ->
            error(conn, 400, "bad_request", "payee rejected")

          true ->
            store(conn, agent, txns)
        end

      {conn, _broken} ->
        error(conn, 400, "bad_request", "broken")
    end
  end

  defp store(conn, agent, txns) do
    {created, lost?} = Agent.get_and_update(agent, &insert(&1, txns))

    if lost?,
      do: error(conn, 500, "internal", "lost"),
      else: data(conn, 201, %{transaction_ids: Enum.map(created, & &1.id), transactions: created})
  end

  defp insert(state, txns) do
    {created, state} = Enum.map_reduce(txns, state, &insert_one/2)
    {{created, state.lost_post}, %{state | lost_post: false}}
  end

  defp insert_one(txn, state) do
    id = "t#{state.next_id + 1}"
    stored = apply_fields(blank(id), txn)
    {stored, %{state | next_id: state.next_id + 1, txns: Map.put(state.txns, id, stored)}}
  end

  defp patch(conn, agent) do
    with {conn, txns} when is_list(txns) <- body_transactions(conn),
         true <-
           Agent.get(agent, fn state -> Enum.all?(txns, &Map.has_key?(state.txns, &1["id"])) end) do
      updated =
        Agent.get_and_update(
          agent,
          &Enum.map_reduce(txns, &1, fn txn, state -> patch_one(state, txn) end)
        )

      data(conn, 200, %{transaction_ids: [], transactions: updated})
    else
      {conn, nil} -> error(conn, 400, "bad_request", "broken")
      false -> error(conn, 404, "not_found", "transaction not found")
    end
  end

  defp patch_one(state, txn) do
    stored = state.txns[txn["id"]]
    stored = if stored.deleted, do: stored, else: apply_fields(stored, txn)
    {stored, put_in(state.txns[stored.id], stored)}
  end

  defp delete(conn, agent, id) do
    case Agent.get_and_update(agent, &delete_one(&1, id)) do
      nil -> error(conn, 404, "not_found", "transaction not found")
      deleted -> data(conn, 200, %{transaction: deleted})
    end
  end

  defp delete_one(state, id) do
    case state.txns[id] do
      %{deleted: false} = txn ->
        {%{txn | deleted: true}, put_in(state.txns[id], %{txn | deleted: true})}

      _gone ->
        {nil, state}
    end
  end

  defp list(conn, agent, account) do
    {txns, bare?} = Agent.get(agent, &{Map.values(&1.txns), &1.bare_list})

    if bare?,
      do: conn |> put_resp_content_type("application/json") |> send_resp(200, "{}"),
      else:
        data(conn, 200, %{
          transactions: Enum.filter(txns, &(not &1.deleted and &1.account_id == account))
        })
  end

  defp blank(id) do
    %{
      id: id,
      account_id: "",
      date: "",
      amount: 0,
      memo: nil,
      payee_name: nil,
      category_id: nil,
      cleared: "",
      approved: false,
      deleted: false
    }
  end

  defp apply_fields(txn, fields) do
    Enum.reduce(fields, txn, fn
      {"category_id", value}, txn ->
        %{txn | category_id: value}

      {key, value}, txn when key in ~w(account_id date amount memo payee_name cleared approved) ->
        Map.put(txn, String.to_existing_atom(key), value)

      _other, txn ->
        txn
    end)
  end

  defp body_transactions(conn) do
    {:ok, body, conn} = read_body(conn)

    case JSON.decode(body) do
      {:ok, %{"transactions" => txns}} when is_list(txns) -> {conn, txns}
      _broken -> {conn, nil}
    end
  end

  defp not_found(conn), do: error(conn, 404, "resource_not_found", "Resource not found")

  defp data(conn, status, data), do: send_json(conn, status, %{data: data})

  defp error(conn, status, name, detail),
    do:
      send_json(conn, status, %{
        error: %{id: Integer.to_string(status), name: name, detail: detail}
      })

  defp send_json(conn, status, body),
    do: conn |> put_resp_content_type("application/json") |> send_resp(status, JSON.encode!(body))
end
