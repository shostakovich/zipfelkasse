defmodule Zipfelkasse.MCP.Access do
  @moduledoc """
  The address of the MCP client. Forwarding headers count only from a trusted proxy:
  X-Forwarded-For is read from the right, and the first hop that is not a trusted proxy is the
  client, since anything left of it may be forged; without it, X-Real-IP. An unparsable hop
  gives no address, so access fails closed.
  """

  alias Zipfelkasse.Network

  @doc """
  The client address, from the connection's `peer`, the X-Forwarded-For header lines and the
  X-Real-IP value; nil if it cannot be known.
  """
  @spec client_ip(:inet.ip_address() | nil, [String.t()], String.t() | nil, [Network.t()]) ::
          :inet.ip_address() | nil
  def client_ip(nil, _forwarded_for, _real_ip, _trusted), do: nil

  def client_ip(peer, forwarded_for, real_ip, trusted) do
    if Network.member?(peer, trusted) do
      hops =
        forwarded_for
        |> Enum.flat_map(&String.split(&1, ","))
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      forwarded(Enum.reverse(hops), peer, real_ip, trusted)
    else
      peer
    end
  end

  defp forwarded([], peer, real_ip, _trusted) do
    case real_ip && String.trim(real_ip) do
      blank when blank in [nil, ""] -> peer
      address -> parse(address)
    end
  end

  defp forwarded(hops, _peer, _real_ip, trusted), do: first_untrusted(hops, nil, trusted)

  defp first_untrusted([], client, _trusted), do: client

  defp first_untrusted([hop | rest], _client, trusted) do
    case parse(hop) do
      nil -> nil
      ip -> if Network.member?(ip, trusted), do: first_untrusted(rest, ip, trusted), else: ip
    end
  end

  defp parse(text) do
    case :inet.parse_strict_address(String.to_charlist(text)) do
      {:ok, ip} -> ip
      {:error, _reason} -> nil
    end
  end

  @doc "An address as text; an IPv4 address mapped into IPv6 as IPv4."
  def format({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: format({div(high, 256), rem(high, 256), div(low, 256), rem(low, 256)})

  def format(nil), do: "invalid IP"
  def format(ip), do: ip |> :inet.ntoa() |> to_string()
end
