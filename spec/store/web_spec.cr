require "./expense_fixture"

private alias Store = Zipfelkasse::Store

private def category_names(s : Store) : Array(String)
  s.list_categories.map(&.name)
end

describe "Store queries for the web UI" do
  it "sets the group name" do
    with_store do |s|
      s.set_group_name(0_i64, "  WG   Kastanienallee ")
      s.group_name.should eq "WG Kastanienallee"
      store_validation_error { s.set_group_name(0_i64, "   ") }
    end
  end

  it "moves categories" do
    with_store do |s|
      first, second = s.list_categories
      s.move_category(0_i64, second.id, true)
      category_names(s)[0, 2].should eq [second.name, first.name]
      # At the edge: nothing happens.
      s.move_category(0_i64, second.id, true)
      category_names(s)[0].should eq second.name
      s.move_category(0_i64, second.id, false)
      category_names(s)[0, 2].should eq [first.name, second.name]
      # Archived ones are skipped and cannot be moved.
      s.set_category_archived(0_i64, second.id, true)
      expect_raises(Store::NotFound) { s.move_category(0_i64, second.id, true) }
      expect_raises(Store::NotFound) { s.move_category(0_i64, 999_i64, true) }
    end
  end

  # New categories go directly before an active "Sonstiges", also after
  # moves renumbered the positions; without one, at the end.
  it "creates categories before Sonstiges after moves" do
    with_store do |s|
      tail = ->(n : Int32) { category_names(s).last(n).join(",") }
      s.move_category(0_i64, s.list_categories[0].id, false)
      s.create_category(0_i64, "Neu")
      tail.call(3).should eq "Geschenke,Neu,Sonstiges"

      # Sonstiges moved up by one: still directly before it.
      sonstiges = s.list_categories.last.id
      s.move_category(0_i64, sonstiges, true)
      s.create_category(0_i64, "Noch neuer")
      tail.call(4).should eq "Geschenke,Noch neuer,Sonstiges,Neu"

      # Without an active Sonstiges: at the end.
      s.set_category_archived(0_i64, sonstiges, true)
      s.create_category(0_i64, "Zuletzt")
      tail.call(3).should eq "Noch neuer,Neu,Zuletzt"
    end
  end

  it "counts expenses per participant and category" do
    with_expense_fixture do |f|
      f.must_create(f.equal("A", 1000, "2026-09-30", f.anna, f.anna, f.ben))
      id = f.must_create(f.equal("B", 1000, "2026-09-30", f.ben, f.ben))
      f.must_create(f.equal("C", 1000, "2026-09-30", f.cleo, f.ben))
      f.s.delete_expense(f.anna, id)

      f.s.expense_count_by_participant.should eq({f.anna => 1, f.ben => 2, f.cleo => 1})
      f.s.expense_count_by_category.should eq({f.food => 2})
    end
  end

  it "lists the category history" do
    with_expense_fixture do |f|
      cats = f.s.list_categories
      other, archived = cats[1].id, cats[2].id
      mk = ->(title : String, d : String, cat : Int64) do
        input = f.equal(title, 1000, d, f.anna, f.anna, f.ben)
        input.category_id = cat
        f.must_create(input)
      end
      mk.call("Kaufland", "2026-09-01", f.food)
      mk.call("Kino", "2026-09-10", other)
      mk.call("Ohne", "2026-09-11", 0_i64)
      mk.call("Archiviert", "2026-09-12", archived)
      gone = mk.call("Gelöscht", "2026-09-13", f.food)
      f.s.delete_expense(f.anna, gone)
      f.s.set_category_archived(0_i64, archived, true)
      back = f.equal("Rückzahlung", 500, "2026-09-14", f.ben, f.anna)
      back.reimbursement = true
      f.s.create_expense(f.ben, back)

      f.s.category_history.should eq [Store::TitleCategory.new("Kino", other), Store::TitleCategory.new("Kaufland", f.food)]
    end
  end
end
