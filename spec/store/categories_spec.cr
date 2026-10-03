require "../spec_helper"

private def category_names(store : Store) : Array(String)
  store.list_categories.map(&.name)
end

describe "Store categories" do
  use_household

  it "manages categories" do
    id = store.create_category(nil, "Haustiere")
    cats = store.list_categories
    cats[-1].name.should eq "Sonstiges"
    cats[-2].id.should eq id
    expect_invalid("Die Kategorie „lebensmittel“ gibt es schon.") { store.create_category(nil, "lebensmittel") }
    store.rename_category(nil, id, "Tiere")
    store.set_category_archived(nil, id, true)
    c = store.get_category(id)
    c.name.should eq "Tiere"
    c.archived?.should be_true
  end

  it "moves categories" do
    first, second = store.list_categories
    store.move_category(nil, second.id, true)
    category_names(store)[0, 2].should eq [second.name, first.name]
    # At the edge: nothing happens.
    store.move_category(nil, second.id, true)
    category_names(store)[0].should eq second.name
    store.move_category(nil, second.id, false)
    category_names(store)[0, 2].should eq [first.name, second.name]
    # Archived ones are skipped and cannot be moved.
    store.set_category_archived(nil, second.id, true)
    expect_raises(Store::NotFound) { store.move_category(nil, second.id, true) }
    expect_raises(Store::NotFound) { store.move_category(nil, 999_i64, true) }
  end

  # New categories go directly before an active "Sonstiges", also after
  # moves renumbered the positions; without one, at the end.
  it "creates categories before Sonstiges after moves" do
    tail = ->(n : Int32) { category_names(store).last(n).join(",") }
    store.move_category(nil, store.list_categories[0].id, false)
    store.create_category(nil, "Neu")
    tail.call(3).should eq "Geschenke,Neu,Sonstiges"

    # Sonstiges moved up by one: still directly before it.
    sonstiges = store.list_categories.last.id
    store.move_category(nil, sonstiges, true)
    store.create_category(nil, "Noch neuer")
    tail.call(4).should eq "Geschenke,Noch neuer,Sonstiges,Neu"

    # Without an active Sonstiges: at the end.
    store.set_category_archived(nil, sonstiges, true)
    store.create_category(nil, "Zuletzt")
    tail.call(3).should eq "Noch neuer,Neu,Zuletzt"
  end

  it "counts the live expenses of a category" do
    h = household
    h.create(h.equal("A", 1000, "2026-09-30", h.anna, h.anna))
    deleted = h.create(h.equal("B", 1000, "2026-09-30", h.anna, h.anna))
    h.create(h.equal("C", 1000, "2026-09-30", h.anna, h.anna))
    store.delete_expense(h.anna, deleted)

    store.expense_count_by_category.should eq({h.food => 2})
  end

  it "lists the category history" do
    h = household
    cats = store.list_categories
    other, archived = cats[1].id, cats[2].id
    mk = ->(title : String, d : String, cat : Int64?) do
      input = h.equal(title, 1000, d, h.anna, h.anna, h.ben)
      input.category_id = cat
      h.create(input)
    end
    mk.call("Kaufland", "2026-09-01", h.food)
    mk.call("Kino", "2026-09-10", other)
    mk.call("Ohne", "2026-09-11", nil)
    mk.call("Archiviert", "2026-09-12", archived)
    gone = mk.call("Gelöscht", "2026-09-13", h.food)
    store.delete_expense(h.anna, gone)
    store.set_category_archived(nil, archived, true)
    back = h.equal("Rückzahlung", 500, "2026-09-14", h.ben, h.anna)
    back.reimbursement = true
    store.create_expense(h.ben, back)

    store.category_history.should eq [Store::TitleCategory.new("Kino", other), Store::TitleCategory.new("Kaufland", h.food)]
  end
end
