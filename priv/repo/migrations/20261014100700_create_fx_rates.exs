defmodule Zipfelkasse.Repo.Migrations.CreateFxRates do
  use Ecto.Migration

  def change do
    create table(:fx_rates, primary_key: false, options: "WITHOUT ROWID") do
      add :currency, :string, null: false, primary_key: true

      add :source, :string,
        null: false,
        primary_key: true,
        check: %{name: "fx_rates_source_check", expr: "source IN ('ecb', 'manual')"}

      add :date, :date, null: false, primary_key: true

      add :rate, :real,
        null: false,
        check: %{name: "fx_rates_rate_check", expr: "rate > 0"}
    end
  end
end
