defmodule Zipfelkasse.Ynab.Cache do
  @moduledoc """
  Keeps YNAB answers that rarely change (plans, categories) for 10 minutes, so the YNAB page does
  not use up the rate limit. Errors are not kept. Keys are hashed: they contain the token.
  """

  use GenServer

  @table __MODULE__
  @ttl :timer.minutes(10)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, nil}
  end

  @doc "The kept value of `key`, or the result of `fun`, kept if it is `{:ok, value}`."
  def fetch(key, refresh?, fun) do
    key = :crypto.hash(:sha256, :erlang.term_to_binary(key))
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, at, value}] when refresh? != true and now - at < @ttl ->
        {:ok, value}

      _missing ->
        with {:ok, value} <- fun.() do
          :ets.insert(@table, {key, now, value})
          {:ok, value}
        end
    end
  end
end
