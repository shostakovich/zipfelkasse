defmodule Zipfelkasse.Repo.Migrations.SeedCategoriesAndSettings do
  use Ecto.Migration

  @categories [
    {"Lebensmittel", 10},
    {"Restaurant", 20},
    {"Haushalt", 30},
    {"Miete & Nebenkosten", 40},
    {"Transport", 50},
    {"Reisen", 60},
    {"Freizeit", 70},
    {"Gesundheit", 80},
    {"Geschenke", 90},
    {"Sonstiges", 1000}
  ]

  def up do
    now = DateTime.to_iso8601(DateTime.utc_now())

    repo().insert_all(
      "categories",
      for {name, position} <- @categories do
        %{name: name, position: position, inserted_at: now, updated_at: now}
      end
    )

    repo().insert_all("settings", [
      %{id: 1, group_name: "Zipfelkasse", inserted_at: now, updated_at: now}
    ])
  end

  def down do
    execute "DELETE FROM settings"
    execute "DELETE FROM categories"
  end
end
