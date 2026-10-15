import Config

config :zipfelkasse, ZipfelkasseWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json"

config :zipfelkasse, forwarded_ssl: true

config :logger, level: :info
