defmodule Zipfelkasse.Money do
  @moduledoc """
  Amounts as integers in the smallest unit of their currency (euro cents for euros), read from
  German or English input and written the German way: `"1.234,56 €"`.

  Input takes a comma or a dot as decimal separator and the other one as thousands separator.
  A single dot before exactly three digits groups thousands (`"1.234"` is 1234), unless the
  currency has three decimals or only zeros precede it (`"0.856"`).
  """

  @max_cents 1_000_000_000_000
  @zero_decimals ~w(JPY KRW ISK HUF CLP VND XAF XOF PYG UGX IDR)
  @three_decimals ~w(KWD BHD OMR JOD TND LYD IQD)
  @int64_bound :math.pow(2, 63)

  @doc "The largest amount in cents, 10 billion euros, so that splitting cannot overflow."
  def max_cents, do: @max_cents

  @doc "Reads an amount with `decimals` decimal places into minor units."
  @spec parse(String.t(), 0..3) :: {:ok, integer()} | {:error, String.t()}
  def parse(text, decimals) do
    text = text |> String.trim() |> String.replace_suffix("€", "") |> String.trim()

    if text == "",
      do: {:error, "Bitte einen Betrag eingeben."},
      else: parse_fixed(text, decimals)
  end

  @doc ~s(Reads a percentage into basis points: `"12,5 %"` is 1250.)
  @spec parse_basis_points(String.t()) :: {:ok, integer()} | {:error, String.t()}
  def parse_basis_points(text) do
    text = text |> String.trim() |> String.replace_suffix("%", "") |> String.trim()

    with {:error, _} <- parse_fixed(text, 2),
         do: {:error, "Ungültige Prozentangabe „#{text}“."}
  end

  @doc "Reads an exchange rate: units of the currency per 1 €. A dot before three digits groups."
  @spec parse_rate(String.t()) :: {:ok, float()} | {:error, String.t()}
  def parse_rate(text) do
    text = text |> String.trim() |> strip_spaces()

    with {:ok, {false, int, frac}} when byte_size(int) <= 12 and byte_size(frac) <= 12 <-
           split_number(text, true),
         {rate, ""} when rate > 0 <- Float.parse(int <> "." <> frac <> "0") do
      {:ok, rate}
    else
      _invalid ->
        {:error,
         "Ungültiger Wechselkurs „#{text}“ – bitte eine Zahl größer als 0 angeben " <>
           "(Einheiten der Währung pro 1 €)."}
    end
  end

  @doc """
  Reads digits with at most `decimals` places after a dot and no thousands separator, as tools
  pass them: `"1.234"` is never 1234.
  """
  @spec parse_decimal(String.t(), 0..3) :: {:ok, non_neg_integer()} | :error
  def parse_decimal(text, decimals) do
    {whole, fraction} =
      case String.split(String.trim(text), ".", parts: 2) do
        [whole, fraction] -> {whole, String.trim_trailing(fraction, "0")}
        [whole] -> {whole, ""}
      end

    if whole =~ ~r/\A[0-9]{1,15}\z/ and fraction =~ ~r/\A[0-9]*\z/ and
         byte_size(fraction) <= decimals,
       do: {:ok, String.to_integer(whole <> String.pad_trailing(fraction, decimals, "0"))},
       else: :error
  end

  defp parse_fixed(text, decimals) do
    text = strip_spaces(text)

    with {:text, true} <- {:text, text != ""},
         {:ok, {negative?, int, frac}} <- split_number(text, decimals < 3),
         frac = trim_zeros(frac, decimals),
         :ok <- check_places(frac, decimals),
         :ok <- check_size(int) do
      value = String.to_integer(int <> String.pad_trailing(frac, decimals, "0"))
      {:ok, if(negative?, do: -value, else: value)}
    else
      {:text, false} -> {:error, "Bitte einen Betrag eingeben."}
      :error -> {:error, "Ungültiger Betrag „#{text}“."}
      {:error, _message} = error -> error
    end
  end

  # Only space and no-break space: U+202F and other spaces are not part of a number.
  defp strip_spaces(text), do: String.replace(text, [" ", " "], "")

  # "1200,00" is 1200 yen, e.g. after switching an amount from euros to yen.
  defp trim_zeros(frac, decimals) do
    if byte_size(frac) > decimals and String.ends_with?(frac, "0"),
      do: trim_zeros(binary_part(frac, 0, byte_size(frac) - 1), decimals),
      else: frac
  end

  defp check_places(frac, decimals) when byte_size(frac) <= decimals, do: :ok
  defp check_places(_frac, 0), do: {:error, "Dieser Betrag darf keine Nachkommastellen haben."}

  defp check_places(_frac, decimals),
    do: {:error, "Höchstens #{decimals} Nachkommastellen erlaubt."}

  defp check_size(int) when byte_size(int) > 15, do: {:error, "Der Betrag ist zu groß."}
  defp check_size(_int), do: :ok

  defp split_number(text, dot_thousands?) do
    {negative?, digits} =
      case text do
        "-" <> rest -> {true, rest}
        "+" <> rest -> {false, rest}
        _unsigned -> {false, text}
      end

    with true <- digits =~ ~r/\A[0-9.,]+\z/,
         {:ok, int, frac, thousands} <- separate(digits, dot_thousands?),
         false <- String.contains?(frac, [".", ","]),
         {:ok, int} <- ungroup(int, thousands) do
      {:ok, {negative?, if(int == "", do: "0", else: int), frac}}
    else
      _invalid -> :error
    end
  end

  defp separate(digits, dot_thousands?) do
    dots = count(digits, ".")
    commas = count(digits, ",")

    cond do
      dots > 0 and commas > 0 -> separate_both(digits, dots, commas)
      dots + commas > 1 -> {:ok, digits, "", if(commas > 0, do: ",", else: ".")}
      dots + commas == 1 -> separate_one(digits, dot_thousands?)
      true -> {:ok, digits, "", nil}
    end
  end

  defp separate_both(digits, dots, commas) do
    {int, separator, frac} = split_at_last(digits, [".", ","])

    case separator do
      "." when dots == 1 -> {:ok, int, frac, ","}
      "," when commas == 1 -> {:ok, int, frac, "."}
      _repeated -> :error
    end
  end

  defp separate_one(digits, dot_thousands?) do
    {int, separator, frac} = split_at_last(digits, [".", ","])

    cond do
      separator == "." and byte_size(frac) == 3 and dot_thousands? and
          String.trim(int, "0") != "" ->
        {:ok, digits, "", "."}

      frac == "" ->
        :error

      true ->
        {:ok, int, frac, nil}
    end
  end

  defp split_at_last(digits, separators) do
    [{position, 1} | _] = digits |> :binary.matches(separators) |> Enum.reverse()

    {binary_part(digits, 0, position), binary_part(digits, position, 1),
     binary_part(digits, position + 1, byte_size(digits) - position - 1)}
  end

  defp ungroup(int, nil), do: if(String.contains?(int, [".", ","]), do: :error, else: {:ok, int})

  defp ungroup(int, thousands) do
    [first | rest] = String.split(int, thousands)

    if first != "" and byte_size(first) <= 3 and Enum.all?(rest, &(byte_size(&1) == 3)),
      do: ungroup(Enum.join([first | rest]), nil),
      else: :error
  end

  defp count(text, char), do: length(:binary.matches(text, char))

  @doc ~s(Euro cents as shown: `"1.234,56 €"`.)
  @spec format_cents(integer()) :: String.t()
  def format_cents(cents), do: format_minor(cents, 2, group: true) <> " €"

  @doc ~s(Euro cents for an input field: `"1234,56"`.)
  @spec format_cents_input(integer()) :: String.t()
  def format_cents_input(cents), do: format_minor(cents, 2)

  @doc ~s(An amount in minor units of `currency`: `"1.234,56 USD"`, euros as `format_cents/1`.)
  @spec format_money(integer(), String.t()) :: String.t()
  def format_money(minor, currency) do
    if eur?(currency) do
      format_cents(minor)
    else
      code = normalize_currency(currency)
      format_minor(minor, decimals(code), group: true) <> " " <> code
    end
  end

  @doc ~s(Minor units of `currency` for an input field: `"1234,56"`, yen `"123456"`.)
  @spec format_minor_input(integer(), String.t()) :: String.t()
  def format_minor_input(minor, currency), do: format_minor(minor, decimals(currency))

  @doc ~s(Basis points as a percentage: `"33,33 %"`.)
  @spec format_basis_points(integer()) :: String.t()
  def format_basis_points(points), do: format_minor(points, 2) <> " %"

  @doc """
  `value` in units of 10^-decimals. Options: `:separator` (default `","`) and `:group` (dots
  between thousands).
  """
  @spec format_minor(integer(), non_neg_integer(), keyword()) :: String.t()
  def format_minor(value, decimals, opts \\ []) do
    scale = Integer.pow(10, decimals)
    whole = Integer.to_string(div(abs(value), scale))
    whole = if opts[:group], do: group(whole), else: whole

    text =
      if decimals > 0 do
        fraction =
          abs(value) |> rem(scale) |> Integer.to_string() |> String.pad_leading(decimals, "0")

        whole <> Keyword.get(opts, :separator, ",") <> fraction
      else
        whole
      end

    if value < 0, do: "-" <> text, else: text
  end

  defp group(digits) do
    digits
    |> String.reverse()
    |> String.to_charlist()
    |> Enum.chunk_every(3)
    |> Enum.join(".")
    |> String.reverse()
  end

  @doc "A rate in the shortest digits that read back as it, with a comma and never an exponent."
  @spec format_rate(float()) :: String.t()
  def format_rate(rate) when is_float(rate) and rate > 0 do
    {digits, point} = rate |> :erlang.float_to_binary([:short]) |> digits_and_point()

    cond do
      point <= 0 ->
        "0," <> String.duplicate("0", -point) <> digits

      point >= byte_size(digits) ->
        digits <> String.duplicate("0", point - byte_size(digits))

      true ->
        binary_part(digits, 0, point) <>
          "," <> binary_part(digits, point, byte_size(digits) - point)
    end
  end

  def format_rate(_rate), do: ""

  # The significant digits of Erlang's shortest form ("1.7e4") and the position of the point.
  defp digits_and_point(short) do
    {mantissa, exponent} =
      case String.split(short, "e") do
        [mantissa, exponent] -> {mantissa, String.to_integer(exponent)}
        [mantissa] -> {mantissa, 0}
      end

    {int, frac} =
      case String.split(mantissa, ".") do
        [int, "0"] -> {int, ""}
        [int, frac] -> {int, frac}
        [int] -> {int, ""}
      end

    {int <> frac, byte_size(int) + exponent}
  end

  @doc ~s(A currency code as stored: `" usd "` is `"USD"`.)
  @spec normalize_currency(String.t()) :: String.t()
  def normalize_currency(currency), do: currency |> String.trim() |> String.upcase()

  @doc "Whether `code` is three ASCII capitals."
  @spec valid_currency?(String.t()) :: boolean()
  def valid_currency?(code), do: code =~ ~r/\A[A-Z]{3}\z/

  @doc "Whether `currency` means euros; an empty one does."
  @spec eur?(String.t()) :: boolean()
  def eur?(currency), do: normalize_currency(currency) in ["", "EUR"]

  @doc "The decimal places of `currency`: 0, 2 or 3."
  @spec decimals(String.t()) :: 0 | 2 | 3
  def decimals(currency) do
    code = normalize_currency(currency)

    cond do
      code in @zero_decimals -> 0
      code in @three_decimals -> 3
      true -> 2
    end
  end

  @doc """
  Converts minor units of `currency` at `rate` (units per 1 €) into euro cents, rounding half
  away from zero.
  """
  @spec to_eur_cents(integer(), String.t(), float()) :: {:ok, integer()} | {:error, String.t()}
  def to_eur_cents(minor, currency, rate) when is_number(rate) and rate > 0 do
    cents = minor / :math.pow(10, decimals(currency)) / rate * 100

    if cents >= -@int64_bound and cents < @int64_bound,
      do: {:ok, round(cents)},
      else: {:error, "Der Betrag ist zu groß."}
  end

  def to_eur_cents(_minor, _currency, _rate),
    do: {:error, "Der Wechselkurs muss größer als 0 sein."}
end
