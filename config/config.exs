import Config

config :zipfelkasse,
  ecto_repos: [Zipfelkasse.Repo],
  generators: [timestamp_type: :utc_datetime_usec],
  jobs: true

config :zipfelkasse, Zipfelkasse.Fx.Ecb, base_url: "https://www.ecb.europa.eu/stats/eurofxref/"

config :zipfelkasse, Zipfelkasse.Repo,
  journal_mode: :wal,
  synchronous: :normal,
  foreign_keys: :on,
  busy_timeout: 15_000,
  # A deferred read-then-write fails with SQLITE_BUSY at once; immediate ones wait at BEGIN.
  default_transaction_mode: :immediate,
  pool_size: 5,
  # :serial is AUTOINCREMENT in SQLite, so ids are never reused.
  migration_primary_key: [type: :serial, null: false],
  migration_timestamps: [type: :utc_datetime_usec]

config :zipfelkasse, Zipfelkasse.Ynab.Client, base_url: "https://api.ynab.com/v1"

config :zipfelkasse, ZipfelkasseWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ZipfelkasseWeb.ErrorHTML, json: ZipfelkasseWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Zipfelkasse.PubSub,
  live_view: [signing_salt: "VcOBGu+f"]

config :phoenix_live_view, root_tag_attribute: "phx-r"

config :esbuild,
  version: "0.25.4",
  zipfelkasse: [
    args: ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :tailwind,
  version: "4.3.3",
  zipfelkasse: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :setzkasten,
  icons: ZipfelkasseWeb.Icons,
  plush: ZipfelkasseWeb.Plush,
  translate_error: {ZipfelkasseWeb.CoreComponents, :translate_error}

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, JSON
config :phoenix, :filter_parameters, ["password", "token", "secret"]
config :ecto_sqlite3, json_library: JSON

import_config "#{config_env()}.exs"
