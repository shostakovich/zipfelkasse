defmodule Zipfelkasse.Activities do
  @moduledoc """
  The activity log: expenses created, changed and deleted, and changes to the settings. Entries
  are written in the transaction of the change they describe.
  """

  import Ecto.Query

  alias Zipfelkasse.Activities.{Activity, Details}
  alias Zipfelkasse.Repo

  @doc "Logs a change to the settings (people, categories, rates, …) described by `text`."
  def log_settings(actor_id, text), do: log(actor_id, :settings_updated, nil, %{text: text})

  @doc """
  Logs `action` on an expense. `details` may hold `:title`, `:amount_cents`, `:changes` and
  `:text`.
  """
  def log(actor_id, action, expense_id, details) do
    Repo.insert(%Activity{
      actor_id: actor_id,
      action: action,
      expense_id: expense_id,
      details: Details.new(details)
    })
  end

  @doc """
  The newest entries first, with their actor. Options: `:limit` (default 50), `:before_id` (the
  entries before it, for paging), `:expense_id` (the history of one expense), `:actor_id`,
  `:action`, and `:since` and `:until`, UTC moments (from inclusive, until exclusive).
  """
  def list_activities(opts \\ []) do
    Activity
    |> order_by(desc: :id)
    |> limit(^Keyword.get(opts, :limit, 50))
    |> filter(opts)
    |> preload(:actor)
    |> Repo.all()
  end

  defp filter(query, opts), do: Enum.reduce(opts, query, &filter_by/2)

  defp filter_by({_option, nil}, query), do: query
  defp filter_by({:before_id, id}, query), do: where(query, [a], a.id < ^id)
  defp filter_by({:expense_id, id}, query), do: where(query, [a], a.expense_id == ^id)
  defp filter_by({:actor_id, id}, query), do: where(query, [a], a.actor_id == ^id)
  defp filter_by({:action, action}, query), do: where(query, [a], a.action == ^action)
  defp filter_by({:since, moment}, query), do: where(query, [a], a.inserted_at >= ^moment)
  defp filter_by({:until, moment}, query), do: where(query, [a], a.inserted_at < ^moment)
  defp filter_by({:limit, _limit}, query), do: query

  @doc "The actions that occur in the log, sorted."
  def list_actions do
    Repo.all(from a in Activity, distinct: true, select: a.action, order_by: a.action)
  end

  @doc "The actions an entry can have."
  def actions, do: Ecto.Enum.values(Activity, :action)
end
