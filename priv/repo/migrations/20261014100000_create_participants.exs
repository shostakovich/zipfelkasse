defmodule Zipfelkasse.Repo.Migrations.CreateParticipants do
  use Ecto.Migration

  def change do
    create table(:participants) do
      add :name, :string,
        null: false,
        collate: :nocase,
        check: %{name: "participants_name_check", expr: "length(trim(name)) > 0"}

      add :archived_at, :utc_datetime_usec

      timestamps()
    end

    create unique_index(:participants, [:name])
  end
end
