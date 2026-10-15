defmodule Zipfelkasse.Fx do
  @moduledoc """
  Exchange rates in units of the currency per 1 €. The rate of a currency on a day is the newest
  manual rate valid then, however old, or else the ECB rate of that day or of up to ten days
  before (weekends, holidays). Euros are 1. ECB rates are loaded when needed (see
  `Zipfelkasse.Fx.Loader`) and every day after their publication.
  """

  import Ecto.Query

  alias Zipfelkasse.{Activities, Dates, LocalTime, Money, Repo}
  alias Zipfelkasse.Expenses.Expense
  alias Zipfelkasse.Fx.{Loader, Rate}

  @lookback_days 10

  @doc """
  The rate of `currency` on `date`; a date after today counts as today. `{:error, :no_rate}`
  when there is none, `{:error, {:unavailable, message}}` when the ECB rates could not be loaded.
  Options: `:today` and `:loader`.
  """
  @spec rate(String.t(), Date.t(), keyword()) ::
          {:ok, Rate.t()} | {:error, :no_rate | {:unavailable, String.t()}}
  def rate(currency, date, opts \\ []) do
    code = Money.normalize_currency(currency)

    cond do
      code == "EUR" -> {:ok, %Rate{currency: "EUR", source: :fixed, date: date, rate: 1.0}}
      Money.valid_currency?(code) -> lookup(code, Enum.min([date, today(opts)], Date), opts)
      true -> {:error, :no_rate}
    end
  end

  defp lookup(code, date, opts) do
    case latest(code, :manual, date, nil) do
      nil -> lookup_ecb(code, date, Loader.ensure(Keyword.get(opts, :loader, Loader), date))
      manual -> {:ok, manual}
    end
  end

  defp lookup_ecb(code, date, loaded) do
    case {latest(code, :ecb, date, Date.add(date, -@lookback_days)), loaded} do
      {%Rate{} = rate, _loaded} -> {:ok, rate}
      {nil, :ok} -> {:error, :no_rate}
      {nil, {:error, message}} -> {:error, {:unavailable, message}}
    end
  end

  defp today(opts), do: Keyword.get_lazy(opts, :today, &LocalTime.today/0)

  defp latest(currency, source, date, not_before) do
    query =
      from r in Rate,
        where: r.currency == ^currency and r.source == ^source and r.date <= ^date,
        order_by: [desc: r.date],
        limit: 1

    query = if not_before, do: where(query, [r], r.date >= ^not_before), else: query
    Repo.one(query)
  end

  @doc "The German message for ECB rates that could not be loaded for `reason`."
  @spec unavailable_message(String.t()) :: String.t()
  def unavailable_message(reason) do
    "Die EZB-Kurse konnten nicht geladen werden (#{reason}). " <>
      "Bitte später erneut versuchen oder den Kurs von Hand eintragen."
  end

  @doc "Loads the newest ECB rates now; gives the newest day or the German error message."
  @spec refresh(GenServer.server()) :: {:ok, Date.t()} | {:error, String.t()}
  def refresh(loader \\ Loader), do: Loader.refresh(loader)

  @doc "Saves ECB rates, replacing those of the same day."
  @spec save_ecb_rates([%{currency: String.t(), date: Date.t(), rate: float()}]) :: :ok
  def save_ecb_rates(rates) do
    {:ok, _saved} =
      Repo.transact(fn ->
        rates
        |> Enum.map(&Map.put(&1, :source, :ecb))
        |> Enum.chunk_every(1000)
        |> Enum.each(
          &Repo.insert_all(Rate, &1,
            on_conflict: {:replace, [:rate]},
            conflict_target: [:currency, :source, :date]
          )
        )

        {:ok, length(rates)}
      end)

    :ok
  end

  @doc "The first and last day of the ECB rates, or nil without any."
  @spec ecb_range() :: Date.Range.t() | nil
  def ecb_range do
    case Repo.one(from r in Rate, where: r.source == :ecb, select: {min(r.date), max(r.date)}) do
      {nil, nil} -> nil
      {first, last} -> Date.range(first, last)
    end
  end

  @doc "How many ECB rates of how many currencies are stored, from and to which day."
  @spec ecb_stats() :: %{
          count: non_neg_integer(),
          currencies: non_neg_integer(),
          from: Date.t() | nil,
          to: Date.t() | nil
        }
  def ecb_stats do
    Repo.one(
      from r in Rate,
        where: r.source == :ecb,
        select: %{
          count: count(),
          currencies: count(r.currency, :distinct),
          from: min(r.date),
          to: max(r.date)
        }
    )
  end

  @doc "The ECB rates of the newest day, by currency."
  @spec latest_ecb_rates() :: [Rate.t()]
  def latest_ecb_rates do
    newest = from r in Rate, where: r.source == :ecb, select: max(r.date)

    Repo.all(
      from r in Rate,
        where: r.source == :ecb and r.date == subquery(newest),
        order_by: r.currency
    )
  end

  @doc "The currencies that have a rate, for choosing one."
  @spec list_currencies() :: [String.t()]
  def list_currencies,
    do: Repo.all(from r in Rate, distinct: true, select: r.currency, order_by: r.currency)

  @doc "The rates of the newest live expenses in another currency than euros, newest first."
  @spec recent_expense_rates(pos_integer()) :: [map()]
  def recent_expense_rates(limit \\ 10) do
    Repo.all(
      from e in Expense,
        where: is_nil(e.deleted_at) and e.original_currency != "EUR",
        order_by: [desc: e.date, desc: e.id],
        limit: ^limit,
        select: %{
          expense_id: e.id,
          title: e.title,
          currency: e.original_currency,
          date: e.date,
          rate: e.fx_rate,
          source: e.fx_source
        }
    )
  end

  @doc "The manual rates by currency, the newest first."
  def list_manual_rates do
    Repo.all(from r in Rate, where: r.source == :manual, order_by: [r.currency, desc: r.date])
  end

  @doc "A changeset for the manual rate form."
  def change_manual_rate(attrs \\ %{}), do: Rate.manual_changeset(%Rate{}, attrs)

  @doc "Saves a manual rate for a currency from a date on, replacing one of the same day."
  def put_manual_rate(actor_id, attrs) do
    Repo.transact(fn ->
      with {:ok, rate} <-
             Repo.insert(Rate.manual_changeset(%Rate{}, attrs),
               on_conflict: {:replace, [:rate]},
               conflict_target: [:currency, :source, :date]
             ),
           {:ok, _activity} <-
             Activities.log_settings(
               actor_id,
               "Manueller Kurs für #{rate.currency} ab #{Dates.format(rate.date)} gespeichert: " <>
                 "1 € = #{Money.format_rate(rate.rate)} #{rate.currency}"
             ) do
        {:ok, rate}
      end
    end)
  end

  @doc "Deletes the manual rate of a currency from a date on; the ECB rates stay."
  def delete_manual_rate(actor_id, currency, date) do
    currency = Money.normalize_currency(currency)

    Repo.transact(fn ->
      case Repo.delete_all(
             from r in Rate,
               where: r.currency == ^currency and r.source == :manual and r.date == ^date
           ) do
        {0, _} ->
          {:error, :not_found}

        {_deleted, _} ->
          Activities.log_settings(
            actor_id,
            "Manueller Kurs für #{currency} ab #{Dates.format(date)} gelöscht"
          )
      end
    end)
  end
end
