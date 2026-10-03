require "./expense_fixture"

private alias Store = Zipfelkasse::Store

# The entries written after the entry with ID after (oldest first) and the ID
# of the newest entry.
private def new_activity(s : Store, after : Int64) : {Array(Store::Activity), Int64}
  all = s.list_activity(Store::ActivityFilter.new(limit: 1000))
  {all.select(&.id.>(after)).reverse, all.first?.try(&.id) || after}
end

# Steps for exchange rates, recurrences and YNAB are in their own specs.
describe "Store activity" do
  it "logs exactly one entry per settings change and none without a change" do
    with_expense_fixture do |f|
      s = f.s
      dora = emil = kino = 0_i64
      steps = [
        {"group name", -> { s.set_group_name(f.anna, " WG  Zipfel ") }, nil,
         "Gruppe umbenannt: „Zipfelkasse“ → „WG Zipfel“"},
        {"group name unchanged", -> { s.set_group_name(f.anna, "WG Zipfel") }, nil, ""},
        {"create person", -> { dora = s.create_participant(f.anna, "Dora"); nil }, nil, "Person „Dora“ hinzugefügt"},
        {"rename person unchanged", -> { s.rename_participant(f.ben, dora, " Dora ") }, f.ben, ""},
        {"rename person", -> { s.rename_participant(f.ben, dora, "Doro") }, f.ben, "Person „Dora“ umbenannt in „Doro“"},
        {"archive person", -> { s.set_participant_archived(f.anna, dora, true) }, nil, "Person „Doro“ archiviert"},
        {"restore person", -> { s.set_participant_archived(f.anna, dora, false) }, nil, "Person „Doro“ reaktiviert"},
        {"join", -> { emil = s.join_as_participant("Emil"); nil }, :emil, "Person „Emil“ hinzugefügt"},
        {"create category", -> { kino = s.create_category(f.anna, "Kino"); nil }, nil, "Kategorie „Kino“ hinzugefügt"},
        {"rename category unchanged", -> { s.rename_category(f.anna, kino, "Kino") }, nil, ""},
        {"rename category", -> { s.rename_category(f.anna, kino, "Theater") }, nil,
         "Kategorie „Kino“ umbenannt in „Theater“"},
        {"move category", -> { s.move_category(f.anna, kino, true) }, nil, "Kategorie „Theater“ nach oben verschoben"},
        {"move category at the edge", -> { s.move_category(f.anna, f.food, true) }, nil, ""},
        {"archive category", -> { s.set_category_archived(f.anna, kino, true) }, nil, "Kategorie „Theater“ archiviert"},
        {"restore category", -> { s.set_category_archived(f.anna, kino, false) }, nil, "Kategorie „Theater“ reaktiviert"},
      ]
      _, last = new_activity(s, 0_i64)
      steps.each do |name, step, actor, want|
        step.call
        acts, last = new_activity(s, last)
        if want.empty?
          {name, acts.size}.should eq({name, 0})
          next
        end
        actor_id = case actor
                   when Int64 then actor
                   when :emil then emil
                   else            f.anna
                   end
        {name, acts.map { |a| {a.action, a.details.text, a.actor_id, a.expense_id} }}
          .should eq({name, [{Store::ACTION_SETTINGS_UPDATED, want, actor_id, 0_i64}]})
      end
    end
  end

  it "logs nothing for failed mutations" do
    with_expense_fixture do |f|
      s = f.s
      _, last = new_activity(s, 0_i64)
      store_validation_error { s.rename_participant(f.anna, f.ben, "anna") }
      store_validation_error { s.set_group_name(f.anna, " ") }
      expect_raises(Store::NotFound) { s.set_category_archived(f.anna, 999_i64, true) }
      expect_raises(Store::NotFound) { s.move_category(f.anna, 999_i64, true) }
      store_validation_error { s.create_category(f.anna, "lebensmittel") }
      new_activity(s, last)[0].should be_empty
    end
  end

  it "rolls back a change whose activity entry fails" do
    with_expense_fixture do |f|
      f.s.db.exec("CREATE TRIGGER no_activity BEFORE INSERT ON activity BEGIN SELECT RAISE(ABORT, 'no activity'); END")
      expect_raises(Exception, "no activity") { f.s.rename_participant(f.anna, f.ben, "Benno") }
      f.s.get_participant(f.ben).name.should eq "Ben"
      expect_raises(Exception, "no activity") { f.s.set_group_name(f.anna, "WG") }
      f.s.group_name.should eq "Zipfelkasse"
      expect_raises(Exception, "no activity") { f.s.create_expense(f.anna, f.equal("Kino", 1000, "2026-09-01", f.anna, f.anna)) }
      f.s.list_expenses.should be_empty
    end
  end
end
