defmodule Zipfelkasse.Fx.Ecb do
  @moduledoc """
  The ECB's euro reference rates: the files of the last 90 days and of the whole history, as
  `<Cube><Cube time="…"><Cube currency="USD" rate="1.1"/>…`. Parsing is strict: a cut-off file
  fails instead of yielding its first rates.
  """

  alias Zipfelkasse.{HTTP, Money}

  @recent "eurofxref-hist-90d.xml"
  @history "eurofxref-hist.xml"
  @user_agent "zipfelkasse/1.0 (self-hosted expense tracker; ECB reference rates)"
  @max_rate 1.0e12

  @type rate :: %{currency: String.t(), date: Date.t(), rate: float()}

  @doc "The file of the last 90 days."
  def recent, do: @recent

  @doc "The file of the whole history."
  def history, do: @history

  @doc "Downloads and parses `file` from `base_url`; an error is a reason in English."
  @spec download(String.t(), String.t()) :: {:ok, [rate()]} | {:error, String.t()}
  def download(base_url, file) do
    case HTTP.get(base_url <> file, [{"user-agent", @user_agent}]) do
      {:ok, 200, body} -> parse(body)
      {:ok, status, _body} -> {:error, "HTTP status #{status}"}
      {:error, reason} -> {:error, describe(reason)}
    end
  end

  defp describe(:timeout), do: "timeout"
  defp describe(:too_large), do: "file too large"
  defp describe({:failed_connect, _details}), do: "no connection"
  defp describe(reason), do: inspect(reason)

  @doc "The rates of every day in the file; currencies or rates the ECB does not have are left out."
  @spec parse(binary()) :: {:ok, [rate()]} | {:error, String.t()}
  def parse(xml) do
    options = [
      {:event_fun, &event/3},
      {:event_state, {[], [], nil}},
      {:continuation_fun, fn state -> {<<>>, state} end},
      {:continuation_state, nil},
      {:external_entities, :none},
      :disallow_entities
    ]

    case :xmerl_sax_parser.stream(xml, options) do
      {:ok, {_stack, rates, invalid_date}, rest} ->
        cond do
          invalid_date -> {:error, "xml: date #{inspect(invalid_date)}"}
          String.trim(rest) != "" -> {:error, "xml: content after the document"}
          rates == [] -> {:error, "file contains no rates"}
          true -> {:ok, Enum.reverse(rates)}
        end

      {_tag, _location, reason, _end_tags, _state} ->
        {:error, "xml: #{reason}"}

      {:error, reason} ->
        {:error, "xml: #{inspect(reason)}"}
    end
  end

  defp event({:startElement, _uri, name, _qualified, attributes}, _location, state) do
    {stack, rates, invalid_date} = state

    case {stack, name} do
      {[], _name} ->
        {[:root], rates, invalid_date}

      {[:root | _], ~c"Cube"} ->
        {[:outer | stack], rates, invalid_date}

      {[:outer | _], ~c"Cube"} ->
        time = attribute(attributes, ~c"time")

        case Date.from_iso8601(time) do
          {:ok, date} -> {[{:day, date} | stack], rates, invalid_date}
          {:error, _reason} -> {[:other | stack], rates, invalid_date || time}
        end

      {[{:day, date} | _], ~c"Cube"} ->
        {[:rate | stack], rate(attributes, date, rates), invalid_date}

      _other ->
        {[:other | stack], rates, invalid_date}
    end
  end

  defp event(
         {:endElement, _uri, _name, _qualified},
         _location,
         {[_element | stack], rates, invalid}
       ),
       do: {stack, rates, invalid}

  defp event(_event, _location, state), do: state

  defp rate(attributes, date, rates) do
    currency = attribute(attributes, ~c"currency")

    case parse_rate(attribute(attributes, ~c"rate")) do
      rate when is_float(rate) ->
        if Money.valid_currency?(currency),
          do: [%{currency: currency, date: date, rate: rate} | rates],
          else: rates

      nil ->
        rates
    end
  end

  defp attribute(attributes, name) do
    Enum.find_value(attributes, "", fn {_uri, _prefix, attribute, value} ->
      attribute == name && List.to_string(value)
    end)
  end

  @doc ~s(A rate as the ECB writes it; `"N/A"`, empty, 0 or less, or absurdly large ones are nil.)
  @spec parse_rate(String.t()) :: float() | nil
  def parse_rate(text) do
    case Float.parse(String.trim(text)) do
      {rate, ""} when rate > 0 and rate <= @max_rate -> rate
      _invalid -> nil
    end
  end
end
