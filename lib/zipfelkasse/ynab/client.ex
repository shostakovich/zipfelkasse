defmodule Zipfelkasse.Ynab.Client do
  @moduledoc """
  YNAB's API with a personal access token; YNAB calls budgets plans. The
  base URL comes from the config. An answer without the expected data is an unclear outcome,
  never an empty list.
  """

  alias Zipfelkasse.HTTP
  alias Zipfelkasse.Ynab.Error

  @timeout 30_000
  @max_body 64 * 1024 * 1024

  @type account :: %{
          id: String.t(),
          name: String.t(),
          on_budget: boolean(),
          closed: boolean(),
          deleted: boolean()
        }
  @type plan :: %{
          id: String.t(),
          name: String.t(),
          currency: String.t() | nil,
          accounts: [account()]
        }
  @type transaction :: %{id: String.t(), memo: String.t() | nil, deleted: boolean()}

  @doc "The plans the token can see, with their accounts."
  @spec plans(String.t()) :: {:ok, [plan()]} | {:error, Error.t()}
  def plans(token) do
    with {:ok, data} <- get(token, "/plans?include_accounts=true"),
         do: decode(data, fn %{"plans" => plans} -> Enum.map(plans, &plan/1) end)
  end

  @doc "The category groups of a plan with their categories."
  def categories(token, plan_id) do
    with {:ok, data} <- get(token, plan_path(plan_id) <> "/categories"),
         do: decode(data, fn %{"category_groups" => groups} -> Enum.map(groups, &group/1) end)
  end

  @doc "An account of a plan."
  def account(token, plan_id, account_id) do
    with {:ok, data} <- get(token, account_path(plan_id, account_id)),
         do: decode(data, fn %{"account" => account} -> account(account) end)
  end

  @doc "The transactions of an account."
  def account_transactions(token, plan_id, account_id) do
    with {:ok, data} <- get(token, account_path(plan_id, account_id) <> "/transactions"),
         do: decode(data, &transactions/1)
  end

  @doc "Creates transactions; returns them as YNAB stored them."
  def create_transactions(token, plan_id, transactions),
    do: save(token, :post, plan_id, transactions)

  @doc "Updates transactions by their `id`; returns them as YNAB stored them."
  def update_transactions(token, plan_id, transactions),
    do: save(token, :patch, plan_id, transactions)

  @doc "Deletes a transaction."
  def delete_transaction(token, plan_id, transaction_id) do
    path = plan_path(plan_id) <> "/transactions/" <> segment(transaction_id)

    with {:ok, _data} <- request(token, :delete, path, nil), do: :ok
  end

  defp save(token, method, plan_id, transactions) do
    with {:ok, data} <-
           request(token, method, plan_path(plan_id) <> "/transactions", %{
             transactions: transactions
           }),
         {:ok, data} <- unwrap(data),
         do: decode(data, &transactions/1)
  end

  defp get(token, path) do
    with {:ok, data} <- request(token, :get, path, nil), do: unwrap(data)
  end

  defp unwrap(body) do
    case JSON.decode(body) do
      {:ok, %{"data" => data}} -> {:ok, data}
      _unreadable -> {:error, Error.unclear("YNAB-Antwort unlesbar: keine Daten")}
    end
  end

  defp decode(data, fun) do
    {:ok, fun.(data)}
  rescue
    _mismatch in [FunctionClauseError, MatchError, CaseClauseError, Protocol.UndefinedError] ->
      {:error, Error.unclear("YNAB-Antwort unlesbar: unerwarteter Aufbau")}
  end

  defp plan(%{"id" => id, "name" => name} = plan) when is_binary(id) and is_binary(name) do
    currency =
      case plan["currency_format"] do
        %{"iso_code" => code} when is_binary(code) -> code
        nil -> nil
      end

    %{
      id: id,
      name: name,
      currency: currency,
      accounts: Enum.map(plan["accounts"] || [], &account/1)
    }
  end

  defp account(%{"id" => id, "name" => name} = account) when is_binary(id) and is_binary(name) do
    %{
      id: id,
      name: name,
      on_budget: flag!(account, "on_budget"),
      closed: flag!(account, "closed"),
      deleted: flag!(account, "deleted")
    }
  end

  defp group(%{"id" => id, "name" => name, "categories" => categories} = group)
       when is_binary(id) and is_binary(name) and is_list(categories) do
    group |> category() |> Map.put(:categories, Enum.map(categories, &category/1))
  end

  defp category(%{"id" => id, "name" => name} = category)
       when is_binary(id) and is_binary(name) do
    %{
      id: id,
      name: name,
      hidden: flag!(category, "hidden"),
      deleted: flag!(category, "deleted"),
      internal: Map.get(category, "internal", false) == true
    }
  end

  defp transactions(%{"transactions" => transactions}) when is_list(transactions),
    do: Enum.map(transactions, &transaction/1)

  defp transaction(%{"id" => id} = transaction) when is_binary(id) do
    memo = transaction["memo"]
    true = is_nil(memo) or is_binary(memo)
    %{id: id, memo: memo, deleted: flag!(transaction, "deleted")}
  end

  defp flag!(map, key) do
    %{^key => flag} = map
    true = is_boolean(flag)
    flag
  end

  defp request(token, method, path, body) do
    headers = [{"authorization", "Bearer " <> token}, {"accept", "application/json"}]

    case HTTP.request(method, base_url() <> path, headers, body,
           timeout: @timeout,
           max_body: @max_body
         ) do
      {:ok, status, _headers, data} when status in 200..299 ->
        {:ok, data}

      {:ok, status, headers, data} ->
        {:error, Error.api(status, detail(data), retry_after(headers))}

      {:error, reason} ->
        {:error, Error.unclear("YNAB nicht erreichbar: #{describe(reason)}")}
    end
  end

  defp describe(:timeout), do: "Zeitüberschreitung"
  defp describe(:too_large), do: "Antwort zu groß"
  defp describe({:failed_connect, _details}), do: "keine Verbindung"
  defp describe(reason), do: inspect(reason)

  defp detail(body) do
    case JSON.decode(body) do
      {:ok, %{"error" => %{} = error}} ->
        Enum.find([error["detail"], error["name"]], &(is_binary(&1) and &1 != ""))

      _unreadable ->
        nil
    end
  end

  defp retry_after(headers) do
    with {_name, value} <- List.keyfind(headers, "retry-after", 0),
         {seconds, ""} when seconds > 0 <- value |> String.trim() |> Integer.parse() do
      seconds
    else
      _none -> 0
    end
  end

  defp plan_path(plan_id), do: "/plans/" <> segment(plan_id)

  defp account_path(plan_id, account_id),
    do: plan_path(plan_id) <> "/accounts/" <> segment(account_id)

  defp segment(text), do: URI.encode(text, &URI.char_unreserved?/1)

  @doc "The base URL of the API, from the config."
  def base_url, do: Application.fetch_env!(:zipfelkasse, __MODULE__)[:base_url]
end
