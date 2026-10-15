defmodule Zipfelkasse.Names do
  @moduledoc "Names and titles as stored: runs of whitespace collapse into single spaces."

  import Ecto.Changeset

  @max_length 60

  @doc "The most characters a name has."
  def max_length, do: @max_length

  @doc ~s(Collapses whitespace: `" WG  Zipfel "` becomes `"WG Zipfel"`.)
  @spec normalize(String.t()) :: String.t()
  def normalize(text), do: text |> String.split() |> Enum.join(" ")

  @doc "Normalizes the name in `field` and checks it is 1 to 60 characters; `what` names its owner."
  @spec validate(Ecto.Changeset.t(), atom(), String.t()) :: Ecto.Changeset.t()
  def validate(changeset, field, what) do
    changeset
    |> update_change(field, &(&1 && normalize(&1)))
    |> validate_required(field, message: "Bitte einen Namen für #{what} angeben.")
    |> validate_length(field,
      max: @max_length,
      count: :codepoints,
      message: "Der Name ist zu lang (höchstens #{@max_length} Zeichen)."
    )
  end
end
