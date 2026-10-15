import Config

alias Zipfelkasse.Network

if System.get_env("PHX_SERVER") do
  config :zipfelkasse, ZipfelkasseWeb.Endpoint, server: true
end

read_env? = config_env() != :test

# Trimmed; an empty value counts as unset.
env = fn name ->
  value = if read_env?, do: name |> System.get_env("") |> String.trim(), else: ""
  if value != "", do: value
end

networks! = fn name, default ->
  case Network.parse_list(env.(name) || default) do
    {:ok, networks} -> networks
    {:error, reason} -> raise "invalid #{name}: #{reason}"
  end
end

config :zipfelkasse, :mcp,
  secret: env.("MCP_SECRET"),
  allowed_cidrs: networks!.("MCP_ALLOWED_CIDRS", "160.79.104.0/21"),
  trusted_proxies: networks!.("TRUSTED_PROXIES", "")

port =
  case Integer.parse(env.("PORT") || "4000") do
    {port, ""} when port in 1..65_535 -> port
    _invalid -> raise "invalid PORT: #{inspect(env.("PORT"))} is not a port number"
  end

if config_env() == :dev do
  config :zipfelkasse, ZipfelkasseWeb.Endpoint, http: [port: port], url: [port: port]
end

if config_env() == :prod do
  env! = fn name, example ->
    env.(name) || raise "environment variable #{name} is missing, e.g. #{example}"
  end

  database = env!.("DATABASE_PATH", "/app/data/zipfelkasse.sqlite3")

  config :zipfelkasse, Zipfelkasse.Repo, database: database
  config :zipfelkasse, :backup_dir, Path.join(Path.dirname(database), "backups")

  host = env!.("PHX_HOST", "kasse.example.org")

  # The origin check runs before ForwardedSSL, so it cannot compare schemes behind the proxy.
  config :zipfelkasse, ZipfelkasseWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port],
    check_origin: ["//" <> host],
    secret_key_base: env!.("SECRET_KEY_BASE", "the output of `openssl rand -hex 64`")
end
