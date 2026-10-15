defmodule ZipfelkasseWeb.ForwardedSSL do
  @moduledoc "TLS ends at the reverse proxy: a request forwarded as HTTPS counts as HTTPS, a plain LAN request stays HTTP."
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(_opts), do: Plug.SSL.init(expires: 63_072_000, subdomains: true, exclude: [])

  @impl true
  def call(conn, ssl) do
    if forwarded_https?(conn) do
      %{conn | scheme: :https, port: 443}
      |> Plug.SSL.call(ssl)
      |> register_before_send(&secure_cookies/1)
    else
      conn
    end
  end

  defp forwarded_https?(conn) do
    case get_req_header(conn, "x-forwarded-proto") do
      [proto | _] ->
        proto |> String.split(",") |> hd() |> String.trim() |> String.downcase() == "https"

      [] ->
        false
    end
  end

  defp secure_cookies(conn) do
    cookies =
      Map.new(conn.resp_cookies, fn {key, opts} -> {key, Map.put(opts, :secure, true)} end)

    %{conn | resp_cookies: cookies}
  end
end
