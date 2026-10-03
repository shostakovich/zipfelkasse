require "../spec_helper"

# The activity entries the block writes, oldest first, as {action, text, actor}.
private def written(& : ->) : Array({Store::Action, String?, Int64?})
  newest = store.list_activity(Store::ActivityFilter.new(limit: 1000)).first?.try(&.id) || 0_i64
  yield
  store.list_activity(Store::ActivityFilter.new(limit: 1000)).select(&.id.>(newest)).reverse.map do |entry|
    {entry.action, entry.details.text, entry.actor_id}
  end
end

private def settings(text : String, actor : Int64?) : Array({Store::Action, String?, Int64?})
  [{Store::Action::SettingsUpdated, text.as(String?), actor.as(Int64?)}]
end

# Exchange rates, recurring expenses and YNAB log their own changes in their own specs.
describe "Store activity" do
  use_household

  describe "settings changes" do
    it "logs the new group name" do
      written { store.set_group_name(household.anna, " WG  Zipfel ") }
        .should eq settings("Gruppe umbenannt: „Zipfelkasse“ → „WG Zipfel“", household.anna)
    end

    it "logs a new person" do
      written { store.create_participant(household.anna, "Dora") }.should eq settings("Person „Dora“ hinzugefügt", household.anna)
    end

    it "logs a person who joins on their own with themselves as the author" do
      joined = 0_i64
      written { joined = store.join_as_participant("Emil") }.should eq settings("Person „Emil“ hinzugefügt", joined)
    end

    it "logs a renamed person with the person who renamed them" do
      dora = store.create_participant(nil, "Dora")

      written { store.rename_participant(household.ben, dora, " Doro ") }
        .should eq settings("Person „Dora“ umbenannt in „Doro“", household.ben)
    end

    it "logs an archived and a reactivated person" do
      written { store.set_participant_archived(household.anna, household.cleo, true) }
        .should eq settings("Person „Cleo“ archiviert", household.anna)
      written { store.set_participant_archived(household.anna, household.cleo, false) }
        .should eq settings("Person „Cleo“ reaktiviert", household.anna)
    end

    it "logs a new category" do
      written { store.create_category(household.anna, "Kino") }.should eq settings("Kategorie „Kino“ hinzugefügt", household.anna)
    end

    it "logs a renamed category" do
      kino = store.create_category(nil, "Kino")

      written { store.rename_category(household.anna, kino, "Theater") }
        .should eq settings("Kategorie „Kino“ umbenannt in „Theater“", household.anna)
    end

    it "logs a moved category" do
      kino = store.create_category(nil, "Kino")

      written { store.move_category(household.anna, kino, true) }
        .should eq settings("Kategorie „Kino“ nach oben verschoben", household.anna)
    end

    it "logs an archived and a reactivated category" do
      written { store.set_category_archived(household.anna, household.food, true) }
        .should eq settings("Kategorie „Lebensmittel“ archiviert", household.anna)
      written { store.set_category_archived(household.anna, household.food, false) }
        .should eq settings("Kategorie „Lebensmittel“ reaktiviert", household.anna)
    end
  end

  describe "changes that change nothing" do
    it "log nothing" do
      kino = store.create_category(nil, "Kino")
      dora = store.create_participant(nil, "Dora")
      store.set_group_name(nil, "WG Zipfel")

      written do
        store.set_group_name(household.anna, "WG Zipfel")
        store.rename_participant(household.ben, dora, " Dora ")
        store.rename_category(household.anna, kino, "Kino")
        store.move_category(household.anna, household.food, true)
      end.should be_empty
    end
  end

  it "logs nothing for failed changes" do
    written do
      expect_invalid("„anna“ gibt es schon.") { store.rename_participant(household.anna, household.ben, "anna") }
      expect_invalid("Bitte einen Namen für die Gruppe angeben.") { store.set_group_name(household.anna, " ") }
      expect_raises(Store::NotFound) { store.set_category_archived(household.anna, 999_i64, true) }
      expect_raises(Store::NotFound) { store.move_category(household.anna, 999_i64, true) }
      expect_invalid("Die Kategorie „lebensmittel“ gibt es schon.") { store.create_category(household.anna, "lebensmittel") }
    end.should be_empty
  end

  it "writes details_json without unset fields and reads it leniently" do
    id = household.create(household.equal("Kino", 1000, "2026-09-01", household.anna, household.anna))
    input = store.get_expense(id).to_input
    input.title = "Theater"
    store.update_expense(household.anna, id, input)
    JSON.parse(store.db.scalar("SELECT details_json FROM activity ORDER BY id DESC LIMIT 1").as(String)).should eq JSON.parse(
      %({"title":"Theater","amount_cents":1000,"changes":[{"field":"Titel","old":"Kino","new":"Theater"}]}))
    store.db.scalar("SELECT details_json FROM activity WHERE action = 'expense_created'").should eq %({"title":"Kino","amount_cents":1000})

    store.db.exec(%(UPDATE activity SET details_json = '{"title":"x","extra":true,"changes":[{"field":"a","old":"b","new":"c"}]}' WHERE action = 'expense_created'))
    store.db.exec(%(UPDATE activity SET details_json = 'kaputt' WHERE action = 'expense_updated'))
    updated, created = store.list_activity(Store::ActivityFilter.new(expense_id: id))
    updated.details.should eq Store::ActivityDetails.new
    created.details.should eq Store::ActivityDetails.new(title: "x", changes: [Store::FieldChange.new("a", "b", "c")])
  end

  it "rolls back a change whose activity entry fails" do
    store.db.exec("CREATE TRIGGER no_activity BEFORE INSERT ON activity BEGIN SELECT RAISE(ABORT, 'no activity'); END")
    expect_raises(Exception, "no activity") { store.rename_participant(household.anna, household.ben, "Benno") }
    store.get_participant(household.ben).name.should eq "Ben"
    expect_raises(Exception, "no activity") { store.set_group_name(household.anna, "WG") }
    store.group_name.should eq "Zipfelkasse"
    expect_raises(Exception, "no activity") { store.create_expense(household.anna, household.equal("Kino", 1000, "2026-09-01", household.anna, household.anna)) }
    store.list_expenses.should be_empty
  end
end
