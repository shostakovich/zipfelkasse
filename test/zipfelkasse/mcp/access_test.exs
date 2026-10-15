defmodule Zipfelkasse.MCP.AccessTest do
  use ExUnit.Case, async: true

  alias Zipfelkasse.MCP.Access
  alias Zipfelkasse.Network

  {:ok, trusted} = Network.parse_list("10.0.0.0/8, 172.16.0.5")
  @trusted trusted

  defp ip(text) do
    {:ok, ip} = :inet.parse_strict_address(String.to_charlist(text))
    ip
  end

  for {name, remote, forwarded_for, real_ip, client} <- [
        {"direct", "1.2.3.4", [], nil, "1.2.3.4"},
        {"direct IPv6", "2001:db8::1", [], nil, "2001:db8::1"},
        {"X-Forwarded-For without a proxy is ignored", "1.2.3.4", ["160.79.104.1"], nil,
         "1.2.3.4"},
        {"X-Real-IP without a proxy is ignored", "1.2.3.4", [], "160.79.104.1", "1.2.3.4"},
        {"proxy with X-Forwarded-For", "10.0.0.2", ["160.79.104.1"], nil, "160.79.104.1"},
        {"an address prepended by the client does not count", "10.0.0.2",
         ["160.79.104.1, 6.6.6.6"], nil, "6.6.6.6"},
        {"proxy chain", "10.0.0.2", ["6.6.6.6, 160.79.104.1, 172.16.0.5"], nil, "160.79.104.1"},
        {"several header lines", "10.0.0.2", ["6.6.6.6", "160.79.104.1"], nil, "160.79.104.1"},
        {"a hop with a port is invalid", "10.0.0.2", ["160.79.104.1:443"], nil, nil},
        {"an unparsable hop is invalid", "10.0.0.2", ["garbage"], nil, nil},
        {"a partly unparsable header is invalid", "10.0.0.2", ["160.79.104.1, garbage"], nil,
         nil},
        {"X-Forwarded-For beats X-Real-IP", "10.0.0.2", ["6.6.6.6"], "160.79.104.1", "6.6.6.6"},
        {"only X-Real-IP", "10.0.0.2", [], "160.79.104.9", "160.79.104.9"},
        {"an unparsable X-Real-IP", "10.0.0.2", [], "garbage", nil},
        {"proxy without header", "10.0.0.2", [], nil, "10.0.0.2"},
        {"only trusted hops", "10.0.0.2", ["10.0.0.3, 10.0.0.4"], nil, "10.0.0.3"},
        {"IPv4-mapped proxy and hop", "::ffff:10.0.0.2", ["::ffff:160.79.104.1"], nil,
         "160.79.104.1"}
      ] do
    test name do
      client =
        Access.client_ip(ip(unquote(remote)), unquote(forwarded_for), unquote(real_ip), @trusted)

      assert unquote(client) == if(client, do: Access.format(client))
    end
  end

  test "has no address for a connection without one" do
    assert Access.client_ip(nil, [], nil, @trusted) == nil
    assert Access.format(nil) == "invalid IP"
  end
end
