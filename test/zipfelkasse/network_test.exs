defmodule Zipfelkasse.NetworkTest do
  use ExUnit.Case, async: true

  alias Zipfelkasse.Network

  defp parse!(text) do
    {:ok, networks} = Network.parse_list(text)
    networks
  end

  defp ip(text) do
    {:ok, ip} = text |> String.to_charlist() |> :inet.parse_strict_address()
    ip
  end

  test "reads networks and single addresses separated by commas and whitespace" do
    networks = parse!(" 10.0.0.0/8, 192.168.1.5\n2001:db8::/32 ,, fd00::1 ")

    for address <- ~w(10.1.2.3 192.168.1.5 2001:db8::7 fd00::1) do
      assert Network.member?(ip(address), networks), address
    end

    for address <- ~w(11.0.0.1 192.168.1.6 2001:db9::1 fd00::2) do
      refute Network.member?(ip(address), networks), address
    end
  end

  test "an empty list has no networks" do
    assert Network.parse_list("") == {:ok, []}
    assert Network.parse_list(" , ") == {:ok, []}
    refute Network.member?(ip("1.2.3.4"), [])
  end

  test "drops the host bits of a network" do
    assert parse!("10.1.2.3/8") == parse!("10.0.0.0/8")
    assert parse!("fd00::1/8") == parse!("fd00::/8")
  end

  test "treats IPv4 and IPv4-mapped IPv6 alike" do
    assert Network.member?(ip("::ffff:192.168.1.5"), parse!("192.168.0.0/16"))
    assert Network.member?(ip("192.168.1.5"), parse!("::ffff:192.168.0.0/112"))
    assert parse!("::ffff:192.168.0.0/112") == parse!("192.168.0.0/16")
    assert parse!("::ffff:1.2.3.4") == parse!("1.2.3.4")
    assert Network.member?(ip("1.2.3.4"), parse!("::/0"))
    refute Network.member?(ip("2001:db8::1"), parse!("0.0.0.0/0"))
  end

  test "the default MCP range is Anthropic's /21" do
    networks = parse!("160.79.104.0/21")

    assert Network.member?(ip("160.79.104.1"), networks)
    assert Network.member?(ip("160.79.111.255"), networks)
    refute Network.member?(ip("160.79.112.0"), networks)
  end

  for {text, reason} <- [
        {"not-a-cidr", ~s("not-a-cidr" is not an IP address or network)},
        {"010.1.2.3", ~s("010.1.2.3" is not an IP address or network)},
        {"1.2.3", ~s("1.2.3" is not an IP address or network)},
        {"1.2.3/8", ~s("1.2.3" is not an IP address)},
        {"1.2.3.4/33", ~s("33" is not a valid prefix length for 1.2.3.4)},
        {"fd00::/129", ~s("129" is not a valid prefix length for fd00::)},
        {"::ffff:1.2.3.4/129", ~s("129" is not a valid prefix length for ::ffff:1.2.3.4)},
        {"10.0.0.0/x", ~s("x" is not a valid prefix length for 10.0.0.0)},
        {"10.0.0.0/+8", ~s("+8" is not a valid prefix length for 10.0.0.0)},
        {"10.0.0.0/", ~s("" is not a valid prefix length for 10.0.0.0)},
        {"10.0.0.0/8/8", ~s("8/8" is not a valid prefix length for 10.0.0.0)}
      ] do
    test "refuses #{inspect(text)}" do
      assert Network.parse_list("10.0.0.0/8, " <> unquote(text)) == {:error, unquote(reason)}
    end
  end
end
