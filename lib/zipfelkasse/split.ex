defmodule Zipfelkasse.Split do
  @moduledoc """
  How an amount is split among people. The weight of a part means, by mode: `:equal` none (stored
  as 1), `:shares` a count of shares, `:percent` basis points summing to 10000, `:amount` minor
  units of the original currency summing to the original amount.

  The euro cents go by the largest remainder; ties take turns by the expense id (the rotation),
  so the extra cent does not always land on the same person.
  """

  alias Zipfelkasse.Money

  @modes [:equal, :shares, :percent, :amount]
  @max_shares 1_000_000
  @max_int64 9_223_372_036_854_775_807

  @type mode :: :equal | :shares | :percent | :amount
  @type part :: %{participant_id: integer(), weight: integer()}
  @type share :: %{participant_id: integer(), weight: integer(), amount_cents: integer()}

  @doc "The split modes."
  def modes, do: @modes

  @doc "The name of a split mode, as shown."
  @spec label(mode()) :: String.t()
  def label(:equal), do: "Gleichmäßig"
  def label(:shares), do: "Nach Anteilen"
  def label(:percent), do: "Nach Prozent"
  def label(:amount), do: "Nach Beträgen"

  @doc "Reads the weight a person enters for `mode`; amounts in minor units of `currency`."
  @spec parse_weight(mode(), String.t(), String.t()) :: {:ok, integer()} | {:error, String.t()}
  def parse_weight(:equal, _currency, _text), do: {:ok, 0}

  def parse_weight(:shares, _currency, text) do
    case Integer.parse(String.trim(text)) do
      {shares, ""} -> {:ok, shares}
      _invalid -> {:error, "Anteile müssen ganze Zahlen sein („#{text}“)."}
    end
  end

  def parse_weight(:percent, _currency, text), do: Money.parse_basis_points(text)
  def parse_weight(:amount, currency, text), do: Money.parse(text, Money.decimals(currency))

  @doc "The decimal places of a weight: shares are whole, percentages have two."
  @spec weight_decimals(mode(), String.t()) :: 0 | 2 | 3
  def weight_decimals(mode, _currency) when mode in [:equal, :shares], do: 0
  def weight_decimals(:percent, _currency), do: 2
  def weight_decimals(:amount, currency), do: Money.decimals(currency)

  @doc """
  Splits `total` euro cents among `parts`, sorted by participant id. Options: `:rotation` (the
  expense id, default 0), `:original` and `:currency` (default `total` in `"EUR"`), which the
  weights of an `:amount` split must add up to; the euro cents follow them in proportion.
  """
  @spec split(mode(), integer(), [part()], keyword()) :: {:ok, [share()]} | {:error, String.t()}
  def split(mode, total, parts, opts \\ []) do
    parts = Enum.sort_by(parts, & &1.participant_id)

    with :ok <- check_total(total),
         :ok <- check_parts(mode, parts),
         {:ok, parts} <-
           check_weights(mode, parts, opts[:original] || total, opts[:currency] || "EUR") do
      cents = allocate(total, Enum.map(parts, & &1.weight), Keyword.get(opts, :rotation, 0))
      {:ok, Enum.zip_with(parts, cents, &Map.put(&1, :amount_cents, &2))}
    end
  end

  defp check_total(total) do
    cond do
      total <= 0 -> {:error, "Der Betrag muss größer als 0 sein."}
      total > Money.max_cents() -> {:error, "Der Betrag ist zu groß."}
      true -> :ok
    end
  end

  defp check_parts(_mode, []),
    do: {:error, "Mindestens eine Person muss an der Ausgabe beteiligt sein."}

  defp check_parts(mode, parts) do
    parts
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {part, index} ->
      cond do
        part.participant_id <= 0 ->
          {:error, "Ungültige Person in der Aufteilung."}

        index > 0 and Enum.at(parts, index - 1).participant_id == part.participant_id ->
          {:error, "Eine Person ist in der Aufteilung doppelt aufgeführt."}

        mode != :equal and part.weight < 0 ->
          {:error, "Anteile dürfen nicht negativ sein."}

        true ->
          nil
      end
    end)
  end

  defp check_weights(:equal, parts, _original, _currency),
    do: {:ok, Enum.map(parts, &%{&1 | weight: 1})}

  defp check_weights(:shares, parts, _original, _currency) do
    cond do
      Enum.any?(parts, &(&1.weight > @max_shares)) ->
        {:error, "Anteile dürfen höchstens #{@max_shares} sein."}

      sum(parts) <= 0 ->
        {:error, "Die Summe der Anteile muss größer als 0 sein."}

      true ->
        {:ok, parts}
    end
  end

  defp check_weights(:percent, parts, _original, _currency) do
    cond do
      Enum.any?(parts, &(&1.weight > 10_000)) ->
        {:error, "Die Prozente müssen zusammen 100 % ergeben."}

      sum(parts) != 10_000 ->
        {:error,
         "Die Prozente müssen zusammen 100 % ergeben " <>
           "(aktuell #{Money.format_basis_points(sum(parts))})."}

      true ->
        {:ok, parts}
    end
  end

  defp check_weights(:amount, parts, original, currency) do
    sum = sum(parts)

    cond do
      sum > @max_int64 ->
        {:error, "Der Betrag ist zu groß."}

      sum != original ->
        {:error,
         "Die Beträge müssen zusammen #{Money.format_money(original, currency)} ergeben " <>
           "(aktuell #{Money.format_money(sum, currency)})."}

      true ->
        {:ok, parts}
    end
  end

  defp sum(parts), do: parts |> Enum.map(& &1.weight) |> Enum.sum()

  @doc """
  Distributes `total` in proportion to `weights` by the largest remainder. Leftover cents go by
  remainder, then position; within a group of tied remainders the order is rotated by `rotation`.
  """
  @spec allocate(integer(), [integer()], integer()) :: [integer()]
  def allocate(total, weights, rotation) do
    sum = Enum.sum(weights)

    if sum == 0,
      do: Enum.map(weights, fn _weight -> 0 end),
      else: allocate(total, weights, sum, rotation)
  end

  defp allocate(total, weights, sum, rotation) do
    floors = Enum.map(weights, &div(total * &1, sum))
    leftover = total - Enum.sum(floors)

    lucky =
      weights
      |> Enum.map(&rem(total * &1, sum))
      |> Enum.with_index()
      |> Enum.sort_by(fn {remainder, index} -> {-remainder, index} end)
      |> Enum.chunk_by(fn {remainder, _index} -> remainder end)
      |> Enum.flat_map(&rotate(&1, rotation))
      |> Enum.take(leftover)
      |> MapSet.new(fn {_remainder, index} -> index end)

    floors
    |> Enum.with_index()
    |> Enum.map(fn {cents, index} -> if index in lucky, do: cents + 1, else: cents end)
  end

  defp rotate(tied, rotation) do
    {front, back} = Enum.split(tied, Integer.mod(rotation, length(tied)))
    back ++ front
  end
end
