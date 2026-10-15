defmodule Zipfelkasse.Repo do
  use Ecto.Repo,
    otp_app: :zipfelkasse,
    adapter: Ecto.Adapters.SQLite3
end
