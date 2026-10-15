import Config

# DATABASE_PATH points a preview at a copy of other data.
other_database = System.get_env("DATABASE_PATH")
database = other_database || Path.expand("../storage/development.sqlite3", __DIR__)

config :zipfelkasse, Zipfelkasse.Repo,
  database: database,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

config :zipfelkasse, :backup_dir, Path.join(Path.dirname(database), "backups")

# A copy of real data holds real YNAB tokens: without YNAB_BASE_URL it gets a dead address.
if ynab_url = System.get_env("YNAB_BASE_URL") || (other_database && "http://127.0.0.1:9") do
  config :zipfelkasse, Zipfelkasse.Ynab.Client, base_url: ynab_url
end

config :zipfelkasse, ZipfelkasseWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "k9Oc+Fk/r/G6dpcTJE7/lxMcXvQ0XzDQrdE962Vxbxp3kiWePQS8FxNVPMiXzvwA",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:zipfelkasse, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:zipfelkasse, ~w(--watch)]}
  ]

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true
