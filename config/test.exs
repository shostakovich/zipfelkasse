import Config

database = Path.expand("../tmp/test#{System.get_env("MIX_TEST_PARTITION")}.sqlite3", __DIR__)

# One connection: the sandbox opens a deferred BEGIN, and a second one flakes with "database busy".
config :zipfelkasse, Zipfelkasse.Repo,
  database: database,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 1

config :zipfelkasse, :backup_dir, Path.join(Path.dirname(database), "backups")

config :zipfelkasse, jobs: false
config :zipfelkasse, Zipfelkasse.Fx.Ecb, base_url: nil

config :zipfelkasse, ZipfelkasseWeb.Endpoint,
  url: [host: "localhost", port: 4002],
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "liiL3s5IL4+/BCc8ogHUrmmI7mXKBoc98QDh41oOJxUP9Mx/4UkpQ1CAEN+rrvKh",
  server: false

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view, enable_expensive_runtime_checks: true

config :phoenix, sort_verified_routes_query_params: true
