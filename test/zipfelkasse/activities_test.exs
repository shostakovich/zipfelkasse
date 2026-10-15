defmodule Zipfelkasse.ActivitiesTest do
  use Zipfelkasse.DataCase

  alias Zipfelkasse.Activities
  alias Zipfelkasse.Activities.Activity

  test "lists the newest entries first and pages before an id" do
    for n <- 1..5, do: {:ok, _activity} = Activities.log_settings(nil, "Eintrag #{n}")

    [newest, second] = Activities.list_activities(limit: 2)
    assert {newest.details.text, second.details.text} == {"Eintrag 5", "Eintrag 4"}

    assert Activities.list_activities(before_id: second.id) |> Enum.map(& &1.details.text) ==
             ["Eintrag 3", "Eintrag 2", "Eintrag 1"]
  end

  test "stores the details as German text and reads them back" do
    {:ok, _activity} =
      Activities.log(nil, :expense_updated, nil, %{
        title: "Theater",
        amount_cents: 1000,
        changes: [%{field: "Titel", old: "Kino", new: "Theater"}]
      })

    assert [%Activity{action: :expense_updated, actor: nil, details: details}] =
             Activities.list_activities()

    assert {details.title, details.amount_cents, details.text} == {"Theater", 1000, nil}
    assert [%{field: "Titel", old: "Kino", new: "Theater"}] = details.changes

    assert Repo.query!("SELECT details FROM activities").rows == [
             [
               ~s({"title":"Theater","amount_cents":1000,) <>
                 ~s("changes":[{"field":"Titel","old":"Kino","new":"Theater"}]})
             ]
           ]
  end

  test "stores the details without empty fields" do
    {:ok, _activity} = Activities.log(nil, :expense_created, nil, %{title: "Kino", text: nil})
    {:ok, _activity} = Activities.log_settings(nil, "Kategorie „Reisen“ archiviert")

    {:ok, _activity} =
      Activities.log(nil, :expense_updated, nil, %{title: "Kino", amount_cents: 900, changes: []})

    {:ok, _activity} = Activities.log(nil, :expense_deleted, nil, %{})

    assert Repo.query!("SELECT details FROM activities ORDER BY id").rows ==
             [
               [~s({"title":"Kino"})],
               [~s({"text":"Kategorie „Reisen“ archiviert"})],
               [~s({"title":"Kino","amount_cents":900})],
               ["{}"]
             ]

    assert [
             %{details: %{title: nil}},
             %{details: %{changes: [], text: nil, amount_cents: 900}} | _
           ] =
             Activities.list_activities()
  end
end
