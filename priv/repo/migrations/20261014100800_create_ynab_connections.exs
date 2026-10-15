defmodule Zipfelkasse.Repo.Migrations.CreateYnabConnections do
  use Ecto.Migration

  def change do
    create table(:ynab_connections, primary_key: false) do
      add :participant_id, references(:participants, type: :integer),
        null: false,
        primary_key: true

      add :token, :string
      add :plan_id, :string
      add :account_id, :string
      add :start_date, :date
      add :connected_at, :utc_datetime_usec
      add :last_run_at, :utc_datetime_usec
      add :last_synced_at, :utc_datetime_usec
      add :summary, :string
      add :error, :string

      add :token_invalid, :boolean,
        null: false,
        default: false,
        check: %{name: "ynab_connections_token_invalid_check", expr: "token_invalid IN (0, 1)"}

      add :retry_at, :utc_datetime_usec
      add :backoff_seconds, :integer, null: false, default: 0

      timestamps()
    end
  end
end
