defmodule Zipfelkasse.Schema do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema

      @timestamps_opts [type: :utc_datetime_usec]
    end
  end

  @doc "A moment with the microsecond precision of `:utc_datetime_usec` fields."
  def usec(%DateTime{microsecond: {microsecond, _precision}} = moment),
    do: %{moment | microsecond: {microsecond, 6}}
end
