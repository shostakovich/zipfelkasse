defmodule ZipfelkasseWeb.ContentSecurityPolicy do
  @moduledoc """
  Phoenix's secure browser headers with a strict content security policy, set in the endpoint
  for every response. Scripts come from the app itself or carry the request's nonce
  (`@csp_nonce`, for the theme script); everything else comes from the app only. LiveView
  connects back to the endpoint's host.
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    nonce = 18 |> :crypto.strong_rand_bytes() |> Base.encode64()

    conn
    |> assign(:csp_nonce, nonce)
    |> Phoenix.Controller.put_secure_browser_headers(%{
      "content-security-policy" => policy(nonce),
      # Not no-referrer: that turns the Origin header of form posts into `null`.
      "referrer-policy" => "same-origin",
      "x-frame-options" => "DENY"
    })
  end

  @doc "The policy for a response whose inline scripts carry `nonce`."
  def policy(nonce, endpoint_url \\ ZipfelkasseWeb.Endpoint.url()) do
    Enum.join(
      [
        "default-src 'self'",
        "script-src 'self' 'nonce-#{nonce}'",
        "style-src 'self'",
        "font-src 'self'",
        "img-src 'self' data:",
        "connect-src 'self' #{socket_origin(endpoint_url)}",
        "object-src 'none'",
        "frame-ancestors 'none'",
        "base-uri 'self'",
        "form-action 'self'"
      ],
      "; "
    )
  end

  defp socket_origin(endpoint_url) do
    case URI.parse(endpoint_url) do
      %URI{scheme: "https"} = uri -> URI.to_string(%{uri | scheme: "wss", port: nil})
      uri -> URI.to_string(%{uri | scheme: "ws"})
    end
  end
end
