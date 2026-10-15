defmodule Zipfelkasse.Fx.Rate do
  @moduledoc """
  An exchange rate in units of the currency per 1 €, valid from its date. ECB and manual rates of
  the same day sit side by side. A looked-up euro rate is `:fixed` and never stored.
  """

  use Zipfelkasse.Schema

  import Ecto.Changeset

  alias Zipfelkasse.Money

  @max_rate 1.0e9

  @type t :: %__MODULE__{}

  @primary_key false
  schema "fx_rates" do
    field :currency, :string, primary_key: true
    field :source, Ecto.Enum, values: [:ecb, :manual], primary_key: true
    field :date, :date, primary_key: true
    field :rate, :float
  end

  @doc "A manual rate entered for a currency from a date on."
  def manual_changeset(rate, attrs) do
    rate
    |> cast(attrs, [:currency, :date, :rate])
    |> update_change(:currency, &Money.normalize_currency/1)
    |> put_change(:source, :manual)
    |> validate_currency()
    |> validate_required(:date, message: "Bitte ein Datum angeben.")
    |> validate_required(:rate, message: "Der Kurs muss größer als 0 sein.")
    |> validate_number(:rate,
      greater_than: 0,
      less_than_or_equal_to: @max_rate,
      message: "Der Kurs muss größer als 0 sein."
    )
  end

  defp validate_currency(changeset) do
    case get_field(changeset, :currency) do
      "EUR" ->
        add_error(changeset, :currency, "Für Euro braucht es keinen Kurs.")

      currency ->
        if Money.valid_currency?(currency || ""),
          do: changeset,
          else:
            add_error(
              changeset,
              :currency,
              "Bitte einen dreistelligen Währungscode angeben (z. B. USD)."
            )
    end
  end
end
