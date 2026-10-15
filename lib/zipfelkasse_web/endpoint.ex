defmodule ZipfelkasseWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :zipfelkasse

  alias Plug.Conn.WrapperError

  @session_options [
    store: :cookie,
    key: "_zipfelkasse_key",
    signing_salt: "CJv155YM",
    same_site: "Lax",
    # The chosen person stays chosen for a year, not just until the browser closes.
    max_age: 365 * 24 * 60 * 60
  ]

  if Application.compile_env(:zipfelkasse, :forwarded_ssl, false) do
    plug ZipfelkasseWeb.ForwardedSSL
  end

  # Before all but the socket transports, so error pages and static files get it too.
  plug ZipfelkasseWeb.ContentSecurityPolicy

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  @fonts Plug.Static.init(
           at: "/setzkasten",
           from: {:setzkasten, "priv/static"},
           only: ~w(fonts),
           cache_control_for_etags: "public, max-age=86400"
         )

  @static Plug.Static.init(
            at: "/",
            from: :zipfelkasse,
            gzip: not code_reloading?,
            only: ZipfelkasseWeb.static_paths(),
            raise_on_missing_only: code_reloading?
          )

  plug :serve_fonts
  plug :serve_static

  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :zipfelkasse
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint], log: {__MODULE__, :log_level, []}

  @parsers Plug.Parsers.init(
             parsers: [:urlencoded, :json],
             pass: ["*/*"],
             length: ZipfelkasseWeb.MCPPlug.max_body(),
             json_decoder: Phoenix.json_library()
           )

  # The MCP plug reads its body itself, after checking the client.
  @unparsed Plug.Parsers.init(parsers: [], pass: ["*/*"])

  plug :parse_body

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug ZipfelkasseWeb.Router

  @doc false
  # Health checks poll /up and would flood the log; the MCP path holds the secret.
  def log_level(%Plug.Conn{path_info: ["up"]}), do: false
  def log_level(%Plug.Conn{path_info: ["mcp" | _rest]}), do: false
  def log_level(_conn), do: :info

  # Wrapped like the router's errors, so an error page keeps the headers set above.
  defp serve_fonts(conn, _opts), do: keep_headers_on_error(conn, Plug.Static, @fonts)
  defp serve_static(conn, _opts), do: keep_headers_on_error(conn, Plug.Static, @static)

  defp parse_body(%Plug.Conn{path_info: ["mcp" | _rest]} = conn, _opts),
    do: Plug.Parsers.call(conn, @unparsed)

  defp parse_body(conn, _opts), do: keep_headers_on_error(conn, Plug.Parsers, @parsers)

  defp keep_headers_on_error(conn, plug, opts) do
    plug.call(conn, opts)
  rescue
    error -> WrapperError.reraise(conn, :error, error, __STACKTRACE__)
  end
end
