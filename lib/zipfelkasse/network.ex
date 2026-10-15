defmodule Zipfelkasse.Network do
  @moduledoc """
  IP networks from the environment (`MCP_ALLOWED_CIDRS`, `TRUSTED_PROXIES`), written as CIDRs
  or single addresses. IPv4 is kept IPv4-mapped (`::ffff:a.b.c.d`), so an IPv4 client seen over
  IPv6 matches the same networks.
  """
  import Bitwise

  @enforce_keys [:bits, :length]
  defstruct [:bits, :length]

  @type t :: %__MODULE__{bits: non_neg_integer(), length: 0..128}

  @v4_mapped 0xFFFF <<< 32

  @doc "Parses networks separated by commas or whitespace; the first invalid one is the error."
  @spec parse_list(String.t()) :: {:ok, [t()]} | {:error, String.t()}
  def parse_list(text), do: text |> String.split(~r/[,\s]+/, trim: true) |> parse_all([])

  defp parse_all([], networks), do: {:ok, Enum.reverse(networks)}

  defp parse_all([text | rest], networks) do
    with {:ok, network} <- parse(text), do: parse_all(rest, [network | networks])
  end

  @doc "Parses `10.0.0.0/8`, `2001:db8::/32` or a single address; host bits are dropped."
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(text) do
    case String.split(text, "/", parts: 2) do
      [address] ->
        with {:ok, ip} <- address(address, "#{inspect(address)} is not an IP address or network") do
          {:ok, new(bits(ip), 128)}
        end

      [address, length] ->
        with {:ok, ip} <- address(address, "#{inspect(address)} is not an IP address"),
             {:ok, length} <- prefix_length(ip, length, address) do
          {:ok, new(bits(ip), length)}
        end
    end
  end

  @doc "Whether the address tuple `ip` lies in one of `networks`."
  @spec member?(:inet.ip_address(), [t()]) :: boolean()
  def member?(ip, networks) do
    bits = bits(ip)
    Enum.any?(networks, &((bits &&& mask(&1.length)) == &1.bits))
  end

  defp address(text, error) do
    case :inet.parse_strict_address(String.to_charlist(text)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _reason} -> {:error, error}
    end
  end

  defp prefix_length(ip, text, address) do
    max = if tuple_size(ip) == 4, do: 32, else: 128

    with true <- text =~ ~r/\A\d{1,3}\z/,
         length when length <= max <- String.to_integer(text) do
      {:ok, length + 128 - max}
    else
      _invalid -> {:error, "#{inspect(text)} is not a valid prefix length for #{address}"}
    end
  end

  defp new(bits, length), do: %__MODULE__{bits: bits &&& mask(length), length: length}

  defp mask(length), do: ((1 <<< length) - 1) <<< (128 - length)

  defp bits({a, b, c, d}), do: @v4_mapped ||| a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d

  defp bits({_, _, _, _, _, _, _, _} = ip),
    do: ip |> Tuple.to_list() |> Enum.reduce(0, &(&2 <<< 16 ||| &1))
end
