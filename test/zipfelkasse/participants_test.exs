defmodule Zipfelkasse.ParticipantsTest do
  use Zipfelkasse.DataCase

  import Zipfelkasse.ActivityTexts
  import Zipfelkasse.Fixtures

  alias Zipfelkasse.{Activities, Expenses, Participants}

  defp person!(name) do
    {:ok, participant} = Participants.create_participant(nil, %{name: name})
    participant
  end

  test "creates a person with a normalized name and logs it" do
    anna = person!("  Anna  ")

    assert %{name: "Anna", archived_at: nil} = Participants.get_participant!(anna.id)
    assert activity_texts(:oldest_first) == ["Person „Anna“ hinzugefügt"]
  end

  test "refuses an empty or long name and a name that exists, regardless of its case" do
    person!("Anna")

    assert {:error, changeset} = Participants.create_participant(nil, %{name: "   "})
    assert errors_on(changeset) == %{name: ["Bitte einen Namen für die Person angeben."]}

    assert {:error, changeset} = Participants.create_participant(nil, %{name: "anna"})
    assert errors_on(changeset) == %{name: ["„anna“ gibt es schon."]}

    assert {:error, changeset} =
             Participants.create_participant(nil, %{name: String.duplicate("ä", 61)})

    assert errors_on(changeset) == %{name: ["Der Name ist zu lang (höchstens 60 Zeichen)."]}

    assert activity_texts(:oldest_first) == ["Person „Anna“ hinzugefügt"]
  end

  test "logs a person who joins on their own with themselves as the actor" do
    {:ok, emil} = Participants.join(%{name: "Emil"})

    assert [%{actor_id: actor_id, action: :settings_updated}] = Activities.list_activities()
    assert actor_id == emil.id
  end

  test "renames a person, but not to the name of another, and logs only a real change" do
    anna = person!("Anna")
    ben = person!("Ben")

    assert {:ok, %{name: "Benedikt"} = benedikt} =
             Participants.rename_participant(anna.id, ben, %{name: " Benedikt "})

    assert {:error, changeset} =
             Participants.rename_participant(anna.id, benedikt, %{name: "ANNA"})

    assert errors_on(changeset) == %{name: ["„ANNA“ gibt es schon."]}
    assert {:ok, _same} = Participants.rename_participant(anna.id, benedikt, %{name: "Benedikt"})

    assert [%{actor_id: actor_id} | _] = Activities.list_activities()
    assert actor_id == anna.id
    assert List.last(activity_texts(:oldest_first)) == "Person „Ben“ umbenannt in „Benedikt“"
    assert length(activity_texts(:oldest_first)) == 3
  end

  test "lists people by name regardless of case, active and archived apart" do
    person!("berta")
    person!("Anna")
    cleo = person!("Cleo")
    {:ok, _cleo} = Participants.archive_participant(nil, cleo)

    assert Enum.map(Participants.list_participants(), & &1.name) == ~w(Anna berta)
    assert Enum.map(Participants.list_participants(:archived), & &1.name) == ~w(Cleo)
    assert Enum.map(Participants.list_participants(:all), & &1.name) == ~w(Anna berta Cleo)
  end

  test "archives and reactivates a person, logging both" do
    cleo = person!("Cleo")

    {:ok, archived} = Participants.archive_participant(nil, cleo)
    assert archived.archived_at
    {:ok, back} = Participants.reactivate_participant(nil, archived)
    assert back.archived_at == nil

    assert Enum.drop(activity_texts(:oldest_first), 1) == [
             "Person „Cleo“ archiviert",
             "Person „Cleo“ reaktiviert"
           ]
  end

  test "archives a person only without a balance, which deleted expenses do not change" do
    h = household()

    expense =
      h |> equal("Einkauf", 1000, "2026-08-01", h.anna, [h.anna, h.ben]) |> create!(h.anna)

    ben = Participants.get_participant!(h.ben)

    assert {:error, changeset} = Participants.archive_participant(nil, ben)

    assert errors_on(changeset) == %{
             archived_at: [
               "Ben hat noch einen Saldo von -5,00 €. Bitte erst ausgleichen, dann archivieren."
             ]
           }

    refute Participants.get_participant!(h.ben).archived_at

    assert {:ok, _cleo} =
             Participants.archive_participant(nil, Participants.get_participant!(h.cleo))

    {:ok, _deleted} = Expenses.delete_expense(h.anna, expense)
    assert {:ok, _ben} = Participants.archive_participant(nil, ben)
  end
end
