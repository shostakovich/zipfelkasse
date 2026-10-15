defmodule Zipfelkasse.SettingsTest do
  use Zipfelkasse.DataCase

  alias Zipfelkasse.{Activities, Participants, Settings}

  test "the group is called Zipfelkasse on a new database" do
    assert Settings.group_name() == "Zipfelkasse"
  end

  test "renames the group with collapsed whitespace and logs it with the actor" do
    {:ok, anna} = Participants.create_participant(nil, %{name: "Anna"})
    {:ok, _settings} = Settings.update_settings(anna.id, %{group_name: " WG  Zipfel "})

    assert Settings.group_name() == "WG Zipfel"

    assert [
             %{
               actor_id: actor_id,
               details: %{text: "Gruppe umbenannt: „Zipfelkasse“ → „WG Zipfel“"}
             }
             | _
           ] =
             Activities.list_activities()

    assert actor_id == anna.id
  end

  test "logs nothing when the name stays, and refuses an empty one" do
    {:ok, _settings} = Settings.update_settings(nil, %{group_name: "Zipfelkasse "})
    assert {:error, changeset} = Settings.update_settings(nil, %{group_name: "  "})

    assert errors_on(changeset) == %{group_name: ["Bitte einen Namen für die Gruppe angeben."]}
    assert Activities.list_activities() == []
  end
end
